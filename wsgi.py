"""Entry for uvicorn."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from app.database import init_db
from app.main import app
init_db()
