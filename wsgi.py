"""Application entry point for uvicorn."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app.database import init_db
from app.main import app

# Initialize DB on import
init_db()
