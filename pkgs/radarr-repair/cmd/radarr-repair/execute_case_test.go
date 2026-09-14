package main

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
	"github.com/booxter/nix-config/radarr-repair/internal/repairexecution"
)

func TestExecuteCaseRunsOneStoredRepair(t *testing.T) {
	t.Parallel()

	arguments, expected := validExecuteCaseArguments(t)
	var got executeCaseConfig
	app := application{executeCase: func(
		_ context.Context,
		config executeCaseConfig,
	) (repairexecution.Result, error) {
		got = config
		return repairexecution.Result{
			ManualImport: &casestore.ManualImportExecution{
				State: casestore.ManualImportImported,
			},
		}, nil
	}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &stderr,
	); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("config = %#v, want %#v", got, expected)
	}
	if stdout.String() != "action=manual_import_file_v1 state=imported resumed=false\n" ||
		stderr.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", stdout.String(), stderr.String())
	}
}

func TestExecuteCaseRequiresExplicitApply(t *testing.T) {
	t.Parallel()

	arguments, _ := validExecuteCaseArguments(t)
	arguments = removeArgument(arguments, "--apply")
	calls := 0
	app := application{executeCase: func(
		context.Context,
		executeCaseConfig,
	) (repairexecution.Result, error) {
		calls++
		return repairexecution.Result{}, nil
	}}
	err := app.run(
		context.Background(), arguments, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{},
	)
	if err == nil || !strings.Contains(err.Error(), "--apply is required") {
		t.Fatalf("error = %v", err)
	}
	if calls != 0 {
		t.Fatalf("execute calls = %d", calls)
	}
}

func TestExecuteCaseRejectsInvalidArgumentsBeforeRunning(t *testing.T) {
	t.Parallel()

	valid, _ := validExecuteCaseArguments(t)
	tests := []struct {
		name      string
		arguments []string
	}{
		{name: "invalid case ID", arguments: replaceArgument(valid, "--case-id", "sha256:invalid")},
		{name: "relative state", arguments: replaceArgument(valid, "--state-directory", "state")},
		{name: "zero stabilization", arguments: replaceArgument(valid, "--stabilization", "0s")},
		{name: "zero poll interval", arguments: replaceArgument(valid, "--poll-interval", "0s")},
		{name: "positional argument", arguments: append(append([]string(nil), valid...), "extra")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			calls := 0
			app := application{executeCase: func(
				context.Context,
				executeCaseConfig,
			) (repairexecution.Result, error) {
				calls++
				return repairexecution.Result{}, nil
			}}
			if err := app.run(
				context.Background(), test.arguments, strings.NewReader(""),
				&bytes.Buffer{}, &bytes.Buffer{},
			); err == nil {
				t.Fatalf("arguments %q were accepted", test.arguments)
			}
			if calls != 0 {
				t.Fatalf("execute calls = %d", calls)
			}
		})
	}
}

func TestExecuteCaseReportsRejection(t *testing.T) {
	t.Parallel()

	arguments, _ := validExecuteCaseArguments(t)
	app := application{executeCase: func(
		context.Context,
		executeCaseConfig,
	) (repairexecution.Result, error) {
		return repairexecution.Result{
			Check: executioncheck.Result{Rejections: []executioncheck.Rejection{
				{Reason: executioncheck.CaseChanged},
				{Reason: executioncheck.AuthorizationChanged},
			}},
		}, nil
	}}
	var stdout bytes.Buffer
	if err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &bytes.Buffer{},
	); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "action=none state=rejected reasons=case_changed,authorization_changed resumed=false\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestExecuteCaseReportsDurableStateWhenExecutionFails(t *testing.T) {
	t.Parallel()

	arguments, _ := validExecuteCaseArguments(t)
	failure := errors.New("Radarr unavailable")
	app := application{executeCase: func(
		context.Context,
		executeCaseConfig,
	) (repairexecution.Result, error) {
		return repairexecution.Result{
			Join:    &casestore.JoinExecution{State: casestore.JoinPublished},
			Resumed: true,
		}, failure
	}}
	var stdout bytes.Buffer
	err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &bytes.Buffer{},
	)
	if !errors.Is(err, failure) {
		t.Fatalf("error = %v", err)
	}
	if stdout.String() != "action=join_parts_v1 state=artifact_published resumed=true\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func validExecuteCaseArguments(t *testing.T) ([]string, executeCaseConfig) {
	t.Helper()
	apiKeyFile := filepath.Join(t.TempDir(), "radarr-api-key")
	stateDirectory := filepath.Join(t.TempDir(), "state")
	caseID := "sha256:" + strings.Repeat("a", 64)
	config := executeCaseConfig{
		RadarrURL:        "http://127.0.0.1:7878",
		RadarrAPIKeyFile: apiKeyFile,
		TransmissionURL:  "http://localhost:9091/transmission/rpc",
		WorkerSocket:     "/run/radarr-repair/worker.sock",
		WorkerRoots: map[string]string{
			"root:archive":   "/data/archive",
			"root:downloads": "/data/downloads",
		},
		StateDirectory:    stateDirectory,
		CaseID:            caseID,
		RequestTimeout:    45 * time.Second,
		CollectionTimeout: 90 * time.Second,
		Stabilization:     20 * time.Minute,
		PollInterval:      3 * time.Second,
	}
	return []string{
		"execute-case",
		"--apply",
		"--case-id", caseID,
		"--state-directory", stateDirectory,
		"--radarr-url", config.RadarrURL,
		"--radarr-api-key-file", apiKeyFile,
		"--transmission-url", config.TransmissionURL,
		"--worker-socket", config.WorkerSocket,
		"--worker-root", "root:downloads=/data/downloads",
		"--worker-root", "root:archive=/data/archive",
		"--request-timeout", "45s",
		"--collection-timeout", "90s",
		"--stabilization", "20m",
		"--poll-interval", "3s",
	}, config
}

func removeArgument(arguments []string, name string) []string {
	result := make([]string, 0, len(arguments))
	for _, argument := range arguments {
		if argument != name {
			result = append(result, argument)
		}
	}
	return result
}
