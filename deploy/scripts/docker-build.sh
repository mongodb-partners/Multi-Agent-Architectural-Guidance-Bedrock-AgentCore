#!/usr/bin/env bash
# Build API + Streamlit images (local tags). Run from repository root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TAG="${TAG:-local}"

echo "Building multi-agent-api:${TAG} (context: repo root)..."
docker build -f api/Dockerfile -t "multi-agent-api:${TAG}" .

echo "Building multi-agent-streamlit:${TAG} (context: ui/)..."
docker build -f ui/Dockerfile -t "multi-agent-streamlit:${TAG}" ui

echo "Done: multi-agent-api:${TAG}  multi-agent-streamlit:${TAG}"
