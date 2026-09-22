package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func validArguments(t *testing.T) []string {
	t.Helper()
	return []string{
		"--lidarr-url", "http://127.0.0.1:8686",
		"--lidarr-api-key-file", filepath.Join(t.TempDir(), "api-key"),
		"--worker-socket", filepath.Join(t.TempDir(), "worker.sock"),
		"--worker-root", "usenet=/downloads",
		"--planner-socket", filepath.Join(t.TempDir(), "planner.sock"),
		"--state-directory", filepath.Join(t.TempDir(), "state"),
	}
}

func TestApplicationObservesWithoutActions(t *testing.T) {
	t.Parallel()

	called := false
	app := application{observe: func(_ context.Context, configuration config) (report, error) {
		called = true
		if configuration.LidarrURL != "http://127.0.0.1:8686" ||
			configuration.RequestLimit != defaultRequestTimeout ||
			configuration.WorkerRoots["usenet"] != "/downloads" || configuration.Apply {
			t.Fatalf("configuration = %#v", configuration)
		}
		return report{Observed: 7, Candidates: 2, Planned: 1, Cached: 1, NoRepair: 1}, nil
	}}
	var stdout, stderr bytes.Buffer
	if err := app.run(context.Background(), validArguments(t), &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if !called || stdout.String() != "observed=7 candidates=2 planned=1 cached=1 "+
		"no_repair=1 actions=0 imported=0 failed=0 apply_disabled=false\n" || stderr.Len() != 0 {
		t.Fatalf("called = %v, stdout = %q, stderr = %q", called, stdout.String(), stderr.String())
	}
}

func TestApplicationRequiresEveryApplyGuard(t *testing.T) {
	t.Parallel()
	base := validArguments(t)
	for _, extra := range [][]string{
		{"--apply"},
		{"--apply", "--allow-action", "import_missing_tracks_v1"},
		{"--allow-action", "import_missing_tracks_v1"},
		{"--kill-switch-file", "/run/lidarr-repair-disable-apply"},
	} {
		arguments := append(append([]string(nil), base...), extra...)
		if err := (application{}).run(
			context.Background(), arguments, &bytes.Buffer{}, &bytes.Buffer{},
		); err == nil {
			t.Fatalf("incomplete apply guards were accepted: %v", extra)
		}
	}
}

func TestApplicationPassesGuardedApplyConfiguration(t *testing.T) {
	t.Parallel()
	arguments := append(
		validArguments(t),
		"--apply", "--allow-action", "import_missing_tracks_v1",
		"--kill-switch-file", "/run/lidarr-repair-disable-apply",
	)
	app := application{observe: func(_ context.Context, configuration config) (report, error) {
		if !configuration.Apply ||
			!configuration.AllowedActions["import_missing_tracks_v1"] ||
			configuration.KillSwitchFile != "/run/lidarr-repair-disable-apply" {
			t.Fatalf("configuration = %#v", configuration)
		}
		return report{Actions: 1, Imported: 1}, nil
	}}
	var stdout bytes.Buffer
	if err := app.run(context.Background(), arguments, &stdout, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), "actions=1 imported=1") {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestApplyDisabledByAnyExistingEntry(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "disable")
	disabled, err := applyDisabled(path)
	if err != nil || disabled {
		t.Fatalf("disabled = %v, error = %v", disabled, err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	disabled, err = applyDisabled(path)
	if err != nil || !disabled {
		t.Fatalf("disabled = %v, error = %v", disabled, err)
	}
}

func TestApplicationRejectsUnsafeConfiguration(t *testing.T) {
	t.Parallel()

	tests := [][]string{
		{"--lidarr-url", "https://lidarr.example"},
		{"--lidarr-url", "http://127.0.0.1:8686", "--lidarr-api-key-file", "key"},
		{"--lidarr-url", "http://127.0.0.1:8686", "--lidarr-api-key-file", "/key", "--state-directory", "state"},
		{"--lidarr-url", "http://127.0.0.1:8686", "--lidarr-api-key-file", "/key", "--state-directory", "/state", "--request-timeout", "0s"},
	}
	for _, arguments := range tests {
		if err := (application{}).run(
			context.Background(), arguments, &bytes.Buffer{}, &bytes.Buffer{},
		); err == nil {
			t.Fatalf("arguments were accepted: %v", arguments)
		}
	}
}

func TestApplicationPreservesObservationFailure(t *testing.T) {
	t.Parallel()

	expected := errors.New("queue failed")
	app := application{observe: func(context.Context, config) (report, error) {
		return report{}, expected
	}}
	err := app.run(
		context.Background(), validArguments(t), &bytes.Buffer{}, &bytes.Buffer{},
	)
	if !errors.Is(err, expected) {
		t.Fatalf("error = %v", err)
	}
}

func TestApplicationHonorsCancellation(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	app := application{observe: func(context.Context, config) (report, error) {
		called = true
		return report{}, nil
	}}
	err := app.run(ctx, validArguments(t), &bytes.Buffer{}, &bytes.Buffer{})
	if !errors.Is(err, context.Canceled) || called {
		t.Fatalf("error = %v, called = %v", err, called)
	}
}

func TestApplicationParsesRequestTimeout(t *testing.T) {
	t.Parallel()

	arguments := append(validArguments(t), "--request-timeout", "45s")
	app := application{observe: func(_ context.Context, configuration config) (report, error) {
		if configuration.RequestLimit != 45*time.Second {
			t.Fatalf("timeout = %s", configuration.RequestLimit)
		}
		return report{}, nil
	}}
	if err := app.run(context.Background(), arguments, &strings.Builder{}, &strings.Builder{}); err != nil {
		t.Fatal(err)
	}
}
