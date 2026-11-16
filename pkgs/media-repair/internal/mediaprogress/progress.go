package mediaprogress

import (
	"context"
	"log/slog"
	"time"
)

type loggerKey struct{}

func WithLogger(ctx context.Context, logger *slog.Logger) context.Context {
	return context.WithValue(ctx, loggerKey{}, logger)
}

func WithFields(ctx context.Context, attributes ...any) context.Context {
	if logger, ok := ctx.Value(loggerKey{}).(*slog.Logger); ok {
		return WithLogger(ctx, logger.With(attributes...))
	}
	return ctx
}

// Start records progress before work begins, so a killed worker still leaves
// its last active phase in the journal. The returned function records its end.
func Start(ctx context.Context, phase string, attributes ...any) func(error) {
	logger, ok := ctx.Value(loggerKey{}).(*slog.Logger)
	if !ok {
		return func(error) {}
	}
	logger = logger.With("phase", phase).With(attributes...)
	started := time.Now()
	logger.InfoContext(ctx, "media phase started")
	return func(err error) {
		attributes := []any{"elapsed_seconds", time.Since(started).Seconds()}
		if err != nil {
			attributes = append(attributes, "error", err)
			if ctx.Err() != nil {
				attributes = append(attributes, "context_error", ctx.Err())
			}
			logger.ErrorContext(ctx, "media phase failed", attributes...)
			return
		}
		logger.InfoContext(ctx, "media phase completed", attributes...)
	}
}
