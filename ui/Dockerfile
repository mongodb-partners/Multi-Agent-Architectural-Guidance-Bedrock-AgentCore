# Streamlit UI — typical builds:
#   docker build -f ui/Dockerfile -t multi-agent-streamlit:local ui
#   docker compose up --build   (from repo root; see compose.yaml)
FROM python:3.12-slim-bookworm

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    STREAMLIT_SERVER_ADDRESS=0.0.0.0 \
    STREAMLIT_SERVER_PORT=8501 \
    STREAMLIT_BROWSER_GATHER_USAGE_STATS=false \
    PIP_NO_CACHE_DIR=1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY pages ./pages
COPY lib ./lib
COPY .streamlit ./.streamlit

EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8501/_stcore/health')" || exit 1

# `opentelemetry-instrument` wires the auto-instrumentation hook (env var
# OTEL_PYTHON_DISTRO=opentelemetry-distro). When OTEL_EXPORTER_OTLP_ENDPOINT
# is set (EC2: http://127.0.0.1:4318 via ADOT sidecar) it exports OTLP/HTTP;
# when unset (local docker compose / DEV_MOCK_BACKENDS=1) it falls back to a
# no-op exporter and the UI continues to run unchanged.
CMD ["opentelemetry-instrument", "streamlit", "run", "app.py", "--server.headless=true"]
