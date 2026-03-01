# Stage 1: Base image with dependencies
FROM python:3.11-alpine AS base

WORKDIR /app

# Install dependencies first (layer caching — faster rebuilds)
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Stage 2: Copy app code
COPY app/app.py .

# Non-root user for security
RUN adduser -D appuser
USER appuser

EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q --spider http://localhost:3000/health || exit 1

# Start with gunicorn (production server)
CMD ["gunicorn", "--bind", "0.0.0.0:3000", "--workers", "2", "app:app"]
