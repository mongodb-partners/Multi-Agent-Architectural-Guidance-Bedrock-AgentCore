# Convenience targets — requires Docker / Docker Compose v2+
.PHONY: docker-build docker-up docker-down docker-logs

docker-build:
	DOCKER_BUILDKIT=1 docker build -f api/Dockerfile -t "multi-agent-api:$${TAG:-local}" .
	DOCKER_BUILDKIT=1 docker build -f ui/Dockerfile -t "multi-agent-streamlit:$${TAG:-local}" ui

docker-up:
	docker compose up --build

docker-down:
	docker compose down

docker-logs:
	docker compose logs -f
