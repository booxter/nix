package telemetry

import (
	"context"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// NewProvider keeps telemetry off the repair path: the SDK drops spans when its
// bounded queue fills, and exporter retries cannot extend a media deadline.
func NewProvider(ctx context.Context, service, endpoint string, options ...otlptracehttp.Option) (*sdktrace.TracerProvider, error) {
	options = append([]otlptracehttp.Option{
		otlptracehttp.WithEndpointURL(endpoint),
		otlptracehttp.WithTimeout(2 * time.Second),
		otlptracehttp.WithRetry(otlptracehttp.RetryConfig{Enabled: false}),
	}, options...)
	exporter, err := otlptracehttp.New(ctx, options...)
	if err != nil {
		return nil, err
	}
	return sdktrace.NewTracerProvider(
		sdktrace.WithResource(resource.NewSchemaless(attribute.String("service.name", service))),
		sdktrace.WithBatcher(exporter,
			sdktrace.WithMaxQueueSize(512),
			sdktrace.WithMaxExportBatchSize(128),
			sdktrace.WithBatchTimeout(time.Second),
			sdktrace.WithExportTimeout(2*time.Second)),
	), nil
}

func Shutdown(provider *sdktrace.TracerProvider) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := provider.Shutdown(ctx); err != nil {
		slog.Warn("flush traces", "error", err)
	}
}
