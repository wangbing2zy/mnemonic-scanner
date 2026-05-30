"""FastAPI application - routes, templates, and server setup."""

import json
import logging
import os
import asyncio
import csv
import io
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import func

from app.config import settings
from app.database import init_db, get_db, Mnemonic, Address, ScanJob
from app.scanner import scan_manager

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

# ---- App setup ----

app = FastAPI(
    title="助记词批量扫描工具",
    description="批量扫描助记词，快速定位有钱包地址",
    version="1.0.0",
)

# Ensure directories exist
os.makedirs(settings.UPLOAD_DIR, exist_ok=True)
os.makedirs("data", exist_ok=True)

# Templates
templates_dir = Path(__file__).parent / "templates"
templates = Jinja2Templates(directory=str(templates_dir))

# Static files
static_dir = Path(__file__).parent / "static"
if not static_dir.exists():
    static_dir.mkdir(parents=True)
app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


# ---- Startup ----

@app.on_event("startup")
async def on_startup():
    init_db()
    logger.info("Database initialized")


# ---- Web Pages ----

@app.get("/", response_class=HTMLResponse)
async def index_page(request: Request):
    """Dashboard / home page."""
    jobs = scan_manager.get_all_jobs(limit=10)
    return templates.TemplateResponse(
        "index.html",
        {"request": request, "jobs": jobs, "chains": settings.CHAIN_NAMES},
    )


@app.get("/upload", response_class=HTMLResponse)
async def upload_page(request: Request):
    """Upload page."""
    return templates.TemplateResponse(
        "upload.html",
        {"request": request, "chains": settings.CHAIN_NAMES, "max_size": settings.MAX_UPLOAD_SIZE_MB},
    )


@app.get("/scan/{job_id}", response_class=HTMLResponse)
async def scan_detail_page(request: Request, job_id: int):
    """Scan detail / progress page."""
    job = scan_manager.get_job_status(job_id)
    if not job:
        return HTMLResponse("Job not found", status_code=404)
    return templates.TemplateResponse(
        "scan_detail.html",
        {"request": request, "job": job, "chains": settings.CHAIN_NAMES},
    )


@app.get("/results", response_class=HTMLResponse)
async def results_page(request: Request,
                       job_id: int = Query(None),
                       chain: str = Query(None),
                       page: int = Query(1)):
    """Results page."""
    data = scan_manager.get_results(job_id=job_id, chain=chain, page=page)
    return templates.TemplateResponse(
        "results.html",
        {
            "request": request,
            "data": data,
            "chains": settings.CHAIN_NAMES,
            "current_chain": chain or "",
            "current_job_id": job_id or "",
        },
    )


@app.get("/generate", response_class=HTMLResponse)
async def generate_page(request: Request):
    """Auto-generate mnemonics page."""
    return templates.TemplateResponse(
        "generate.html",
        {
            "request": request,
            "chains": settings.CHAIN_NAMES,
        },
    )


# ---- REST API ----

@app.post("/api/upload")
async def api_upload(file: UploadFile = File(...)):
    """Upload a .txt file with mnemonics (one per line)."""
    if not file.filename.endswith(".txt"):
        raise HTTPException(status_code=400, detail="Only .txt files are supported")

    content = await file.read()
    text = content.decode("utf-8", errors="ignore")

    lines = text.splitlines()
    mnemonics = []
    skipped = 0

    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        words = line.split()
        if len(words) not in (12, 15, 18, 21, 24):
            skipped += 1
            continue
        mnemonics.append(line.lower())

    if not mnemonics:
        raise HTTPException(status_code=400, detail="No valid mnemonics found in file")

    # Save to database
    db = get_db()
    imported = 0
    for mnemonic_text in mnemonics:
        existing = db.query(Mnemonic).filter(Mnemonic.mnemonic == mnemonic_text).first()
        if not existing:
            db.add(Mnemonic(mnemonic=mnemonic_text))
            imported += 1

    db.commit()

    total_in_db = db.query(func.count(Mnemonic.id)).scalar()
    pending = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "pending").scalar()
    db.close()

    return {
        "success": True,
        "imported": imported,
        "skipped": skipped,
        "total_in_db": total_in_db,
        "pending": pending,
        "message": f"Imported {imported} mnemonics, skipped {skipped} invalid lines. "
                   f"Total in DB: {total_in_db}, pending scan: {pending}",
    }


@app.post("/api/scan/start")
async def api_start_scan(chains: str = Form(...),
                         concurrency: int = Form(10)):
    """Start a new scan job."""
    try:
        chain_list = json.loads(chains)
    except (json.JSONDecodeError, TypeError):
        raise HTTPException(status_code=400, detail="Invalid chains format")

    if not chain_list:
        raise HTTPException(status_code=400, detail="At least one chain must be selected")

    for c in chain_list:
        if c not in settings.CHAIN_NAMES:
            raise HTTPException(status_code=400, detail=f"Unknown chain: {c}")

    db = get_db()
    total = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "pending").scalar()
    if total == 0:
        db.close()
        raise HTTPException(status_code=400, detail="No pending mnemonics to scan. Upload some first!")

    # Create job
    job = ScanJob(
        status="pending",
        total_mnemonics=total,
        concurrency=concurrency,
    )
    job.set_chains(chain_list)
    db.add(job)
    db.commit()
    job_id = job.id
    db.close()

    # Start background scan
    asyncio.create_task(scan_manager.start_scan(job_id, chain_list, concurrency))

    return {"success": True, "job_id": job_id, "total_mnemonics": total}


@app.post("/api/scan/generate")
async def api_start_generate(chains: str = Form(...),
                              concurrency: int = Form(10),
                              count: int = Form(100),
                              word_count: int = Form(12),
                              stop_on_find: int = Form(0)):
    """Start auto-generating and scanning mnemonics."""
    chain_list = json.loads(chains)
    if not chain_list:
        raise HTTPException(status_code=400, detail="Select at least one chain")
    for c in chain_list:
        if c not in settings.CHAIN_NAMES:
            raise HTTPException(status_code=400, detail=f"Unknown chain: {c}")
    if word_count not in (12, 24):
        raise HTTPException(status_code=400, detail="Word count must be 12 or 24")

    db = get_db()
    job = ScanJob(
        status="running_generating",
        total_mnemonics=0,
        concurrency=concurrency,
        generated_count=0,
        generated_total=count,
        stop_on_find=stop_on_find,
        word_count=word_count,
        current_phase="generating",
        current_message="Starting generation...",
    )
    job.set_chains(chain_list)
    db.add(job)
    db.commit()
    job_id = job.id
    db.close()

    asyncio.create_task(
        scan_manager.start_generating(job_id, chain_list, concurrency,
                                       count, word_count, bool(stop_on_find))
    )

    return {"success": True, "job_id": job_id, "count": count}


@app.post("/api/scan/{job_id}/stop")
async def api_stop_scan(job_id: int):
    """Stop a running scan."""
    scan_manager.stop_scan(job_id)
    return {"success": True, "message": "Scan stopped"}


@app.get("/api/scan/{job_id}/status")
async def api_scan_status(job_id: int):
    """Get scan job status."""
    job = scan_manager.get_job_status(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


@app.get("/api/scan/{job_id}/stream")
async def api_scan_stream(job_id: int, request: Request):
    """SSE stream for real-time scan progress."""
    async def event_generator():
        last_msg = ""
        while True:
            # Check if client disconnected
            if await request.is_disconnected():
                break

            job = scan_manager.get_job_status(job_id)
            if not job:
                yield f"data: {json.dumps({'error': 'Job not found'})}\n\n"
                break

            current_msg = json.dumps(job)
            if current_msg != last_msg:
                yield f"data: {current_msg}\n\n"
                last_msg = current_msg

            if job["status"] in ("completed", "cancelled", "error"):
                yield f"data: {current_msg}\n\n"
                break

            await asyncio.sleep(1)

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/api/jobs")
async def api_list_jobs():
    """List all scan jobs."""
    return scan_manager.get_all_jobs()


@app.get("/api/results")
async def api_results(job_id: int = Query(None),
                      chain: str = Query(None),
                      min_balance: float = Query(0),
                      page: int = Query(1),
                      per_page: int = Query(50)):
    """Get found wallets with pagination."""
    data = scan_manager.get_results(
        job_id=job_id, chain=chain,
        min_balance=min_balance,
        page=page, per_page=per_page,
    )
    return data


@app.get("/api/results/export")
async def api_export_results(job_id: int = Query(None),
                              chain: str = Query(None),
                              fmt: str = Query("csv")):
    """Export found wallets."""
    results = scan_manager.export_results(job_id=job_id, chain=chain)

    if fmt == "json":
        return JSONResponse(content={"results": results})
    else:
        # CSV export
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["助记词", "链", "链名称", "地址", "余额", "派生路径"])
        for r in results:
            writer.writerow([
                r["mnemonic"], r["chain"], r["chain_name"],
                r["address"], r["balance"], r["derivation_path"],
            ])

        return StreamingResponse(
            iter([output.getvalue()]),
            media_type="text/csv",
            headers={
                "Content-Disposition": f"attachment; filename=found_wallets_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv",
            },
        )


@app.get("/api/stats")
async def api_stats():
    """Get overall statistics."""
    db = get_db()
    total_mnemonics = db.query(func.count(Mnemonic.id)).scalar()
    derived = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "derived").scalar()
    errors = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "error").scalar()
    pending = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "pending").scalar()

    total_addresses = db.query(func.count(Address.id)).scalar()
    checked = db.query(func.count(Address.id)).filter(Address.checked == True).scalar()
    found = db.query(func.count(Address.id)).filter(Address.has_funds == True).scalar()

    # Per-chain breakdown
    chain_stats = {}
    for chain_key, chain_name in settings.CHAIN_NAMES.items():
        count = db.query(func.count(Address.id)).filter(Address.chain == chain_key).scalar()
        found_count = db.query(func.count(Address.id)).filter(
            Address.chain == chain_key, Address.has_funds == True
        ).scalar()
        if count > 0:
            chain_stats[chain_key] = {"name": chain_name, "addresses": count, "found": found_count}

    db.close()

    return {
        "mnemonics": {
            "total": total_mnemonics,
            "derived": derived,
            "pending": pending,
            "errors": errors,
        },
        "addresses": {
            "total": total_addresses,
            "checked": checked,
            "found": found,
        },
        "chains": chain_stats,
    }


# ---- Run ----

def run():
    """Entry point for running the app."""
    import uvicorn
    uvicorn.run(
        "app.main:app",
        host=settings.HOST,
        port=settings.PORT,
        reload=False,
        workers=1,  # Use 1 worker to avoid DB conflicts with background tasks
        log_level="info",
    )


if __name__ == "__main__":
    run()
