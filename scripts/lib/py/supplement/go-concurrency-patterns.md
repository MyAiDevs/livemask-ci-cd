# Go Concurrency Patterns for livemask-backend

> Supplement document — concurrency patterns used in livemask
> Source: Go blog + Effective Go + livemask-backend codebase

## Worker Pool Pattern (Asynq)

```go
// Asynq server handles worker pool automatically
srv := asynq.NewServer(redisClient, asynq.Config{
    Concurrency: 10, // 10 concurrent workers
    Queues: map[string]int{
        "critical": 6,
        "default":  3,
        "low":      1,
    },
})
```

## Fan-Out Pattern (Parallel Processing)

```go
func processNodes(ctx context.Context, nodes []Node) error {
    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(10) // max 10 concurrent

    for _, node := range nodes {
        node := node // capture
        g.Go(func() error {
            return processNode(ctx, node)
        })
    }
    return g.Wait()
}
```

## Graceful Shutdown

```go
ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer cancel()

srv := &http.Server{Addr: ":8080", Handler: router}
go srv.ListenAndServe()

<-ctx.Done()
shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
defer shutdownCancel()
srv.Shutdown(shutdownCtx)
```

## Rate Limiting

```go
limiter := rate.NewLimiter(rate.Limit(100), 1) // 100 req/s
if !limiter.Allow() {
    return &RateLimitError{RetryAfter: time.Second}
}
```

## Context Propagation

```go
// Always pass context through the entire call chain
func (s *Service) GetUser(ctx context.Context, id uuid.UUID) (*User, error) {
    // Context carries: trace ID, auth info, deadline, cancellation
    return s.repo.FindByID(ctx, id)
}
```
