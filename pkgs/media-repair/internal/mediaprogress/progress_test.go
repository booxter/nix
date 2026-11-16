package mediaprogress

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"testing"
)

func TestProgressIdentifiesTimedOutPhase(t *testing.T) {
	var output bytes.Buffer
	ctx := WithLogger(context.Background(), slog.New(slog.NewJSONHandler(&output, nil)))
	ctx = WithFields(ctx, "job", 756, "attempt", 1)
	ctx, cancel := context.WithCancel(ctx)
	finish := Start(ctx, "normalize", "part", 2)
	if output.Len() == 0 {
		t.Fatal("active phase was not logged before completion")
	}
	cancel()
	finish(errors.New("ffmpeg terminated"))

	decoder := json.NewDecoder(&output)
	for _, message := range []string{"media phase started", "media phase failed"} {
		var record struct {
			Message      string   `json:"msg"`
			Job          int      `json:"job"`
			Attempt      int      `json:"attempt"`
			Phase        string   `json:"phase"`
			Part         int      `json:"part"`
			Elapsed      *float64 `json:"elapsed_seconds"`
			Error        string   `json:"error"`
			ContextError string   `json:"context_error"`
		}
		if err := decoder.Decode(&record); err != nil {
			t.Fatal(err)
		}
		if record.Message != message || record.Job != 756 || record.Attempt != 1 ||
			record.Phase != "normalize" || record.Part != 2 {
			t.Fatalf("phase cannot be attributed: %+v", record)
		}
		if message == "media phase failed" && (record.Elapsed == nil || *record.Elapsed < 0 ||
			record.Error != "ffmpeg terminated" || record.ContextError != context.Canceled.Error()) {
			t.Fatalf("failure diagnostics incomplete: %+v", record)
		}
	}
}
