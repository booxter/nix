package telemetry

import (
	"context"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func NewProvider(ctx context.Context, service, endpoint string) (*sdktrace.TracerProvider, error) {
	// The local Unix socket uses filesystem permissions, not TLS credentials.
	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithTimeout(2*time.Second),
		otlptracegrpc.WithRetry(otlptracegrpc.RetryConfig{Enabled: false}),
	)
	if err != nil {
		return nil, err
	}

	// A full queue drops spans instead of blocking a repair. Export and shutdown
	// budgets are separate from the media operation's deadline.
	identity := resource.NewSchemaless(attribute.String("service.name", service))
	batcher := sdktrace.WithBatcher(exporter,
		sdktrace.WithMaxQueueSize(512),
		sdktrace.WithMaxExportBatchSize(128),
		sdktrace.WithBatchTimeout(time.Second),
		sdktrace.WithExportTimeout(2*time.Second),
	)
	return sdktrace.NewTracerProvider(sdktrace.WithResource(identity), batcher), nil
}

func Shutdown(provider *sdktrace.TracerProvider) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := provider.Shutdown(ctx); err != nil {
		slog.Warn("flush traces", "error", err)
	}
}
