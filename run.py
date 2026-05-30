"""Entry point for running the mnemonic scanner application."""

import os
import sys

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app.main import run

if __name__ == "__main__":
    run()
