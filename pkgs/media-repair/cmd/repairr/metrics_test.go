package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/repair"
)

func TestMetricsReportQueueProgressAndOperatorDisable(t *testing.T) {
	directory := t.TempDir()
	store, err := jobs.Open(filepath.Join(directory, "jobs.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	if _, err := store.Observe(ctx, jobs.Job{Service: jobs.Lidarr, QueueID: 42}); err != nil {
		t.Fatal(err)
	}
	scheduler := &repair.Scheduler{
		Disabled: func() (bool, error) { return true, nil },
	}
	scheduler.LastObservation.Store(1234)
	path := filepath.Join(directory, "repairr.prom")
	if err := writeMetrics(ctx, path, store, map[jobs.Service]*repair.Scheduler{jobs.Lidarr: scheduler}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		`repairr_jobs{service="lidarr",state="observed"} 1`,
		`repairr_jobs{service="lidarr",state="importing"} 0`,
		`repairr_queue_observed_timestamp_seconds{service="lidarr"} 1234`,
		`repairr_repairs_disabled{service="lidarr"} 1`,
	} {
		if !strings.Contains(string(data), expected) {
			t.Fatalf("missing metric %s in %s", expected, data)
		}
	}
}

func TestDisableFileChecksFailClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "disable")
	disabled, err := repairsDisabled(path)
	if err != nil || disabled {
		t.Fatalf("absent flag disables repairs: %t %v", disabled, err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	disabled, err = repairsDisabled(path)
	if err != nil || !disabled {
		t.Fatalf("flag ignored: %t %v", disabled, err)
	}
	disabled, err = repairsDisabled(filepath.Join(path, "not-a-directory"))
	if err == nil || !disabled {
		t.Fatalf("filesystem error allowed repairs: %t %v", disabled, err)
	}
}

func TestMetricsLoopStopsOnShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		reportMetrics(ctx, filepath.Join(t.TempDir(), "metrics.prom"), nil, nil)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("metrics loop did not stop")
	}
}
