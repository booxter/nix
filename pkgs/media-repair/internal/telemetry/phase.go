package telemetry

import (
	"context"
	"errors"
	"log/slog"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

type loggerKey struct{}

func WithLogger(ctx context.Context, logger *slog.Logger) context.Context {
	return context.WithValue(ctx, loggerKey{}, logger)
}

// StartPhase uses the parent's provider so helpers and tests need no global
// tracer. Keep a start log: an abruptly killed process cannot export its span.
func StartPhase(ctx context.Context, name string, attributes ...attribute.KeyValue) (context.Context, trace.Span) {
	tracer := trace.SpanFromContext(ctx).TracerProvider().Tracer("repairr.media")
	ctx, span := tracer.Start(ctx, name, trace.WithAttributes(attributes...))

	logger, ok := ctx.Value(loggerKey{}).(*slog.Logger)
	if !ok {
		logger = slog.Default()
	}

	fields := []any{"phase", name}
	if span.SpanContext().IsValid() {
		fields = append(fields,
			"trace_id", span.SpanContext().TraceID().String(),
			"span_id", span.SpanContext().SpanID().String(),
		)
	}
	for _, value := range attributes {
		fields = append(fields, string(value.Key), value.Value.AsInterface())
	}
	logger.InfoContext(ctx, "media phase started", fields...)
	return ctx, span
}

func EndPhase(ctx context.Context, span trace.Span, err error) {
	if err != nil {
		err = errors.Join(err, ctx.Err())
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	span.End()
}
