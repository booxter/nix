package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func TestPhaseLinksStartLogAndCancellationToParentTrace(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder))
	defer provider.Shutdown(context.Background())
	ctx, parent := provider.Tracer("test").Start(context.Background(), "attempt")
	defer parent.End()
	var output bytes.Buffer
	ctx = WithLogger(ctx, slog.New(slog.NewJSONHandler(&output, nil)))
	ctx, cancel := context.WithCancel(ctx)
	ctx, span := StartPhase(ctx, "normalize", attribute.Int("part", 2))
	var record struct {
		Phase   string `json:"phase"`
		TraceID string `json:"trace_id"`
		SpanID  string `json:"span_id"`
		Part    int    `json:"part"`
	}
	if err := json.NewDecoder(&output).Decode(&record); err != nil {
		t.Fatalf("missing live phase log: %v", err)
	}
	if record.Phase != "normalize" || record.Part != 2 ||
		record.TraceID != parent.SpanContext().TraceID().String() || record.SpanID != span.SpanContext().SpanID().String() {
		t.Fatalf("uncorrelated phase log: %+v", record)
	}
	if len(recorder.Ended()) != 0 {
		t.Fatal("phase ended before its work")
	}
	cancel()
	EndPhase(ctx, span, errors.New("ffmpeg terminated"))
	completed := recorder.Ended()
	if len(completed) != 1 || completed[0].Parent().SpanID() != parent.SpanContext().SpanID() ||
		completed[0].Status().Code != codes.Error || !strings.Contains(completed[0].Status().Description, "context canceled") {
		t.Fatalf("missing child span failure: %v", completed)
	}
}
