# Docker Development Stack

> Supplement document — local Docker Compose stack for livemask development
> Source: livemask-ci-cd docker-compose.yml

## Service Layout

| Service | Container | Port Mapping | Dependencies |
|---------|-----------|-------------|--------------|
| Backend API | livemask-local-backend-1 | 18080→8080 | postgres, redis |
| Admin UI | livemask-local-admin-1 | 3001→3000 | backend |
| Website | livemask-local-website-1 | 3002→5173 | backend |
| NodeAgent | livemask-local-nodeagent-1 | 19090→9100 | backend |
| Job Service | livemask-local-job-service-1 | 19191→19191 | backend, postgres, redis |
| PostgreSQL | livemask-local-postgres-1 | 15432→5432 | — |
| Redis | livemask-local-redis-1 | 16379→6379 | — |

## Network

All services are on a shared Docker network (`livemask-local-network`) for internal DNS resolution.
Services refer to each other by container name (e.g. `http://livemask-local-backend-1:8080`).

## Building

```bash
# Build all services
cd livemask-ci-cd && docker compose build

# Start all services
docker compose up -d

# Check status
docker compose ps

# View logs
docker compose logs -f livemask-local-backend-1

# Stop all
docker compose down
```

## Data Persistence

- PostgreSQL data: `pgdata` Docker volume
- Redis data: `redis-data` Docker volume
- To reset: `docker compose down -v` (destroys volumes)
