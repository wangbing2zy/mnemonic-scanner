FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create data and upload directories
RUN mkdir -p data uploads

# Expose port
EXPOSE 8000

# Run with uvicorn
CMD ["uvicorn", "wsgi:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--log-level", "info"]
