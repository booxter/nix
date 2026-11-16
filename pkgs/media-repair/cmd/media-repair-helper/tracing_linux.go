package main

import (
	"context"

	"github.com/booxter/nix-config/media-repair/internal/telemetry"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
)

func (config configuration) startTracing(ctx context.Context) (context.Context, func(error), error) {
	provider, err := telemetry.NewProvider(ctx, "repairr", config.traceEndpoint)
	if err != nil {
		return ctx, nil, err
	}
	ctx = propagation.TraceContext{}.Extract(ctx, propagation.MapCarrier{
		"traceparent": config.traceparent,
		"tracestate":  config.tracestate,
	})
	ctx, span := provider.Tracer("repairr.helper").Start(ctx, "helper "+config.operation)
	return ctx, func(err error) {
		if err != nil {
			span.RecordError(err)
			span.SetStatus(codes.Error, err.Error())
		}
		span.End()
		telemetry.Shutdown(provider)
	}, nil
}
