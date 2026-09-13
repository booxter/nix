package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/plannerclient"
	shadowrunner "github.com/booxter/nix-config/radarr-repair/internal/shadow"
)

func TestShadowRunsOnceAndPrintsSummary(t *testing.T) {
	t.Parallel()

	arguments, apiKeyFile, stateDirectory := validShadowArguments(t)
	var gotConfig shadowConfig
	wantReport := shadowrunner.Report{
		Observed: 12, Stored: 3, Submitted: 4, Decided: 3,
		AlreadyDecided: 5, Deferred: 3, Failed: 1,
	}
	app := application{shadow: func(
		_ context.Context,
		config shadowConfig,
	) (shadowrunner.Report, error) {
		gotConfig = config
		return wantReport, nil
	}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &stderr,
	); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "observed=12 stored=3 submitted=4 decided=3 "+
		"already_decided=5 deferred=3 failed=1\n" || stderr.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", stdout.String(), stderr.String())
	}
	wantConfig := shadowConfig{
		RadarrURL:        "http://127.0.0.1:7878",
		RadarrAPIKeyFile: apiKeyFile,
		TransmissionURL:  "http://localhost:9091/transmission/rpc",
		WorkerSocket:     "/run/radarr-repair/worker.sock",
		WorkerRoots: map[string]string{
			"root:archive":   "/data/archive",
			"root:downloads": "/data/downloads",
		},
		PlannerSocket:     "/run/radarr-repair/planner.sock",
		StateDirectory:    stateDirectory,
		RequestTimeout:    45 * time.Second,
		CollectionTimeout: 90 * time.Second,
		PlannerTimeout:    3 * time.Minute,
		RetryInitial:      7 * time.Minute,
		RetryMaximum:      time.Hour,
	}
	if !reflect.DeepEqual(gotConfig, wantConfig) {
		t.Fatalf("config = %#v, want %#v", gotConfig, wantConfig)
	}
}

func TestShadowPrintsSummaryWhenRunFails(t *testing.T) {
	t.Parallel()

	arguments, _, _ := validShadowArguments(t)
	wantErr := errors.New("one case failed")
	app := application{shadow: func(
		context.Context,
		shadowConfig,
	) (shadowrunner.Report, error) {
		return shadowrunner.Report{Observed: 2, Decided: 1, Failed: 1}, wantErr
	}}
	var stdout bytes.Buffer
	err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &bytes.Buffer{},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v", err)
	}
	if stdout.String() != "observed=2 stored=0 submitted=0 decided=1 "+
		"already_decided=0 deferred=0 failed=1\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestShadowRejectsInvalidConfigurationBeforeRunning(t *testing.T) {
	t.Parallel()

	valid, _, _ := validShadowArguments(t)
	tests := []struct {
		name      string
		arguments []string
	}{
		{name: "missing arguments", arguments: []string{"shadow"}},
		{
			name:      "relative planner socket",
			arguments: replaceArgument(valid, "--planner-socket", "planner.sock"),
		},
		{
			name:      "filesystem root state",
			arguments: replaceArgument(valid, "--state-directory", string(filepath.Separator)),
		},
		{
			name:      "zero request timeout",
			arguments: replaceArgument(valid, "--request-timeout", "0s"),
		},
		{
			name:      "zero collection timeout",
			arguments: replaceArgument(valid, "--collection-timeout", "0s"),
		},
		{
			name:      "zero planner timeout",
			arguments: replaceArgument(valid, "--planner-timeout", "0s"),
		},
		{
			name:      "zero initial retry",
			arguments: replaceArgument(valid, "--retry-initial", "0s"),
		},
		{
			name:      "maximum below initial retry",
			arguments: replaceArgument(valid, "--retry-maximum", "1m"),
		},
		{name: "positional argument", arguments: append(valid, "extra")},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			calls := 0
			app := application{shadow: func(
				context.Context,
				shadowConfig,
			) (shadowrunner.Report, error) {
				calls++
				return shadowrunner.Report{}, nil
			}}
			if err := app.run(
				context.Background(), test.arguments, strings.NewReader(""),
				&bytes.Buffer{}, &bytes.Buffer{},
			); err == nil {
				t.Fatalf("arguments %q were accepted", test.arguments)
			}
			if calls != 0 {
				t.Fatal("shadow run started with invalid configuration")
			}
		})
	}
}

func TestClassifyPlannerFailure(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want casestore.PlanningFailure
	}{
		{
			name: "unavailable",
			err:  &plannerclient.Failure{Kind: plannerclient.FailureUnavailable},
			want: casestore.PlanningFailure{Kind: casestore.PlanningFailureUnavailable},
		},
		{
			name: "timeout",
			err: fmt.Errorf(
				"wrapped: %w", &plannerclient.Failure{Kind: plannerclient.FailureTimeout},
			),
			want: casestore.PlanningFailure{Kind: casestore.PlanningFailureTimeout},
		},
		{
			name: "HTTP",
			err: &plannerclient.Failure{
				Kind: plannerclient.FailureHTTP, StatusCode: 503,
			},
			want: casestore.PlanningFailure{
				Kind: casestore.PlanningFailureHTTP, StatusCode: 503,
			},
		},
		{
			name: "invalid result",
			err:  &plannerclient.Failure{Kind: plannerclient.FailureInvalidResponse},
			want: casestore.PlanningFailure{Kind: casestore.PlanningFailureInvalidResult},
		},
		{
			name: "unexpected",
			err:  errors.New("unexpected"),
			want: casestore.PlanningFailure{Kind: casestore.PlanningFailureUnexpected},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := classifyPlannerFailure(test.err); got != test.want {
				t.Fatalf("failure = %#v, want %#v", got, test.want)
			}
		})
	}
}

func validShadowArguments(t *testing.T) ([]string, string, string) {
	t.Helper()
	apiKeyFile := filepath.Join(t.TempDir(), "radarr-api-key")
	stateDirectory := filepath.Join(t.TempDir(), "state")
	return []string{
		"shadow",
		"--radarr-url", "http://127.0.0.1:7878",
		"--radarr-api-key-file", apiKeyFile,
		"--transmission-url", "http://localhost:9091/transmission/rpc",
		"--worker-socket", "/run/radarr-repair/worker.sock",
		"--worker-root", "root:downloads=/data/downloads",
		"--worker-root", "root:archive=/data/archive",
		"--planner-socket", "/run/radarr-repair/planner.sock",
		"--state-directory", stateDirectory,
		"--request-timeout", "45s",
		"--collection-timeout", "90s",
		"--planner-timeout", "3m",
		"--retry-initial", "7m",
		"--retry-maximum", "1h",
	}, apiKeyFile, stateDirectory
}
