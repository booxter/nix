package telemetry

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	collector "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/protobuf/proto"
)

func TestShutdownExportsCompletedSpans(t *testing.T) {
	received := make(chan *collector.ExportTraceServiceRequest, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
		}
		request := new(collector.ExportTraceServiceRequest)
		if err := proto.Unmarshal(data, request); err != nil {
			t.Error(err)
		}
		received <- request
		w.Header().Set("Content-Type", "application/x-protobuf")
	}))
	defer server.Close()
	provider, err := NewProvider(context.Background(), "repairr-test", server.URL+"/v1/traces")
	if err != nil {
		t.Fatal(err)
	}
	_, span := provider.Tracer("test").Start(context.Background(), "repair attempt")
	span.End()
	if err := provider.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
	select {
	case request := <-received:
		resources := request.GetResourceSpans()
		if len(resources) != 1 || resources[0].ScopeSpans[0].Spans[0].Name != "repair attempt" {
			t.Fatalf("missing completed span: %v", request)
		}
	default:
		t.Fatal("shutdown did not flush the batch")
	}
}
