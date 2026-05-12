# Convenience targets — requires Docker / Docker Compose v2+
.PHONY: docker-build docker-up docker-down docker-logs

docker-build:
	./deploy/scripts/docker-build.sh

docker-up:
	docker compose up --build

docker-down:
	docker compose down

docker-logs:
	docker compose logs -f
