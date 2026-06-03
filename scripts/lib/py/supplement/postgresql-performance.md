# PostgreSQL Performance Guide

> Supplement document — PostgreSQL tuning for livemask-backend
> Source: https://www.postgresql.org/docs/current/ + livemask deployment experience

## Connection Pool Settings (pgxpool)

```go
config, _ := pgxpool.ParseConfig(dsn)
config.MaxConns = 50
config.MinConns = 10
config.MaxConnLifetime = 30 * time.Minute
config.MaxConnIdleTime = 5 * time.Minute
config.HealthCheckPeriod = 1 * time.Minute
```

## Indexing Strategy for livemask

- All foreign keys: always index
- status + created_at: composite index for task/job/node listing queries
- user_id + created_at: for user-centric pagination
- node_id + timestamp: for time-series and heartbeat queries
- Partial indexes: `CREATE INDEX ... WHERE status = 'active'` for hot rows

## Common Migration Patterns

```sql
-- Safe column add with default
ALTER TABLE users ADD COLUMN referral_code VARCHAR(64) UNIQUE;
-- Backfill in batches (avoid long-running lock)
UPDATE users SET referral_code = gen_random_uuid()::text WHERE referral_code IS NULL LIMIT 1000;
```

## Query Performance Tips

1. Use `EXPLAIN ANALYZE` before deploying new queries
2. Prefer `LIMIT` + `OFFSET` cursor over `OFFSET` for pagination
3. Use `pg_stat_statements` to identify slow queries
4. Use connection pooling (pgxpool) — never open/close per request
5. CTEs are optimization fences in PG — materialize explicitly when needed
6. Use `jsonb` for flexible config fields, not EAV
