package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
)

func TestInspectWritesRedactedCaseToNewFile(t *testing.T) {
	t.Parallel()

	output := filepath.Join(t.TempDir(), "case.json")
	arguments, apiKeyFile := validInspectArguments(t, output)
	var gotConfig inspectConfig
	app := application{inspect: func(
		_ context.Context,
		config inspectConfig,
	) (casebuilder.Assembly, error) {
		gotConfig = config
		return casebuilder.Assembly{EncodedRequest: []byte(`{"case_id":"sha256:test"}`)}, nil
	}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &stderr,
	); err != nil {
		t.Fatal(err)
	}
	if stdout.Len() != 0 || stderr.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", stdout.String(), stderr.String())
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"case_id":"sha256:test"}` {
		t.Fatalf("output = %q", data)
	}
	info, err := os.Stat(output)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("output mode = %o", info.Mode().Perm())
	}
	wantConfig := inspectConfig{
		RadarrURL:         "http://127.0.0.1:7878",
		RadarrAPIKeyFile:  apiKeyFile,
		TransmissionURL:   "http://localhost:9091/transmission/rpc",
		SABnzbdURL:        "http://localhost:8080/sabnzbd/api",
		SABnzbdAPIKeyFile: "/run/credentials/sabnzbd-api-key",
		WorkerSocket:      "/run/radarr-repair/worker.sock",
		WorkerRoots: map[string]string{
			"root:archive":   "/data/archive",
			"root:downloads": "/data/downloads",
		},
		Output:            output,
		QueueID:           71,
		Timeout:           45 * time.Second,
		CollectionTimeout: 90 * time.Second,
	}
	if !reflect.DeepEqual(gotConfig, wantConfig) {
		t.Fatalf("config = %#v, want %#v", gotConfig, wantConfig)
	}
}

func TestInspectCanWriteOnlyCaseBytesToStandardOutput(t *testing.T) {
	t.Parallel()

	arguments, _ := validInspectArguments(t, "-")
	app := application{inspect: func(
		context.Context,
		inspectConfig,
	) (casebuilder.Assembly, error) {
		return casebuilder.Assembly{EncodedRequest: []byte(`{"case":"redacted"}`)}, nil
	}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &stderr,
	); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != `{"case":"redacted"}` || stderr.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", stdout.String(), stderr.String())
	}
}

func TestInspectAllWritesExactCasesToNewPrivateDirectory(t *testing.T) {
	t.Parallel()

	outputDirectory := filepath.Join(t.TempDir(), "capture")
	arguments, apiKeyFile := validInspectAllArguments(t, outputDirectory)
	firstID := "sha256:" + strings.Repeat("a", 64)
	secondID := "sha256:" + strings.Repeat("b", 64)
	first := []byte(`{"case_id":"` + firstID + `"}`)
	second := []byte(`{"case_id":"` + secondID + `"}`)
	var gotConfig inspectConfig
	app := application{inspectAll: func(
		_ context.Context,
		config inspectConfig,
	) ([]casebuilder.Assembly, error) {
		gotConfig = config
		return []casebuilder.Assembly{
			{Request: contracts.RepairCaseV3{CaseID: firstID}, EncodedRequest: first},
			{Request: contracts.RepairCaseV3{CaseID: secondID}, EncodedRequest: second},
		}, nil
	}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &stderr,
	); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "captured 2 repair cases\n" || stderr.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", stdout.String(), stderr.String())
	}
	for _, expected := range []struct {
		name string
		data []byte
	}{
		{name: strings.Repeat("a", 64) + ".json", data: first},
		{name: strings.Repeat("b", 64) + ".json", data: second},
	} {
		path := filepath.Join(outputDirectory, expected.name)
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(data, expected.data) {
			t.Fatalf("output %s = %q", expected.name, data)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("output %s mode = %o", expected.name, info.Mode().Perm())
		}
	}
	info, err := os.Stat(outputDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("output directory mode = %o", info.Mode().Perm())
	}
	wantConfig := inspectConfig{
		RadarrURL:         "http://127.0.0.1:7878",
		RadarrAPIKeyFile:  apiKeyFile,
		TransmissionURL:   "http://localhost:9091/transmission/rpc",
		SABnzbdURL:        "http://localhost:8080/sabnzbd/api",
		SABnzbdAPIKeyFile: "/run/credentials/sabnzbd-api-key",
		WorkerSocket:      "/run/radarr-repair/worker.sock",
		WorkerRoots: map[string]string{
			"root:archive":   "/data/archive",
			"root:downloads": "/data/downloads",
		},
		OutputDirectory:   outputDirectory,
		All:               true,
		Timeout:           45 * time.Second,
		CollectionTimeout: 90 * time.Second,
	}
	if !reflect.DeepEqual(gotConfig, wantConfig) {
		t.Fatalf("config = %#v, want %#v", gotConfig, wantConfig)
	}
}

func TestInspectRefusesExistingOutputBeforeCollection(t *testing.T) {
	t.Parallel()

	output := filepath.Join(t.TempDir(), "case.json")
	if err := os.WriteFile(output, []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}
	arguments, _ := validInspectArguments(t, output)
	calls := 0
	app := application{inspect: func(
		context.Context,
		inspectConfig,
	) (casebuilder.Assembly, error) {
		calls++
		return casebuilder.Assembly{}, nil
	}}
	err := app.run(context.Background(), arguments, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("error = %v", err)
	}
	if calls != 0 {
		t.Fatal("inspection ran before the existing output was rejected")
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "existing" {
		t.Fatalf("existing output changed to %q", data)
	}
}

func TestInspectAllRefusesExistingDirectoryBeforeCollection(t *testing.T) {
	t.Parallel()

	outputDirectory := t.TempDir()
	arguments, _ := validInspectAllArguments(t, outputDirectory)
	calls := 0
	app := application{inspectAll: func(
		context.Context,
		inspectConfig,
	) ([]casebuilder.Assembly, error) {
		calls++
		return nil, nil
	}}
	err := app.run(
		context.Background(), arguments, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{},
	)
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("error = %v", err)
	}
	if calls != 0 {
		t.Fatal("bulk inspection ran before the existing directory was rejected")
	}
}

func TestInspectFailureCreatesNoOutput(t *testing.T) {
	t.Parallel()

	output := filepath.Join(t.TempDir(), "case.json")
	arguments, _ := validInspectArguments(t, output)
	wantErr := errors.New("collection failed")
	app := application{inspect: func(
		context.Context,
		inspectConfig,
	) (casebuilder.Assembly, error) {
		return casebuilder.Assembly{}, wantErr
	}}
	err := app.run(context.Background(), arguments, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v", err)
	}
	if _, err := os.Lstat(output); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("output exists after failure: %v", err)
	}
}

func TestInspectHonorsCancellationBeforeCollection(t *testing.T) {
	t.Parallel()

	arguments, _ := validInspectArguments(t, "-")
	app := application{inspect: func(
		context.Context,
		inspectConfig,
	) (casebuilder.Assembly, error) {
		t.Fatal("inspection ran after cancellation")
		return casebuilder.Assembly{}, nil
	}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := app.run(ctx, arguments, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

func TestInspectRejectsInvalidConfigurationBeforeCollection(t *testing.T) {
	t.Parallel()

	valid, _ := validInspectArguments(t, "-")
	validAll, _ := validInspectAllArguments(t, filepath.Join(t.TempDir(), "capture"))
	tests := []struct {
		name      string
		arguments []string
	}{
		{name: "missing arguments", arguments: []string{"inspect"}},
		{
			name:      "remote Radarr",
			arguments: replaceArgument(valid, "--radarr-url", "http://radarr.example:7878"),
		},
		{
			name:      "HTTPS Radarr",
			arguments: replaceArgument(valid, "--radarr-url", "https://localhost:7878"),
		},
		{
			name:      "remote Transmission",
			arguments: replaceArgument(valid, "--transmission-url", "http://transmission.example:9091"),
		},
		{
			name:      "remote SABnzbd",
			arguments: replaceArgument(valid, "--sabnzbd-url", "http://sabnzbd.example:8080"),
		},
		{
			name:      "SABnzbd URL without credential",
			arguments: replaceArgument(valid, "--sabnzbd-api-key-file", ""),
		},
		{
			name:      "SABnzbd credential without URL",
			arguments: replaceArgument(valid, "--sabnzbd-url", ""),
		},
		{
			name:      "relative credential",
			arguments: replaceArgument(valid, "--radarr-api-key-file", "api-key"),
		},
		{
			name:      "relative socket",
			arguments: replaceArgument(valid, "--worker-socket", "worker.sock"),
		},
		{
			name:      "negative queue ID",
			arguments: replaceArgument(valid, "--queue-id", "-1"),
		},
		{
			name:      "output directory without all",
			arguments: append(append([]string(nil), valid...), "--output-directory", "/tmp/cases"),
		},
		{
			name:      "bulk mode with queue ID",
			arguments: append(append([]string(nil), validAll...), "--queue-id", "71"),
		},
		{
			name:      "bulk mode with single output",
			arguments: append(append([]string(nil), validAll...), "--output", "-"),
		},
		{
			name:      "relative bulk output directory",
			arguments: replaceArgument(validAll, "--output-directory", "cases"),
		},
		{
			name:      "zero timeout",
			arguments: replaceArgument(valid, "--timeout", "0s"),
		},
		{
			name:      "zero collection timeout",
			arguments: replaceArgument(valid, "--collection-timeout", "0s"),
		},
		{name: "unexpected positional argument", arguments: append(valid, "extra")},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			calls := 0
			app := application{inspect: func(
				context.Context,
				inspectConfig,
			) (casebuilder.Assembly, error) {
				calls++
				return casebuilder.Assembly{}, nil
			}}
			if err := app.run(
				context.Background(), test.arguments, strings.NewReader(""),
				&bytes.Buffer{}, &bytes.Buffer{},
			); err == nil {
				t.Fatalf("arguments %q were accepted", test.arguments)
			}
			if calls != 0 {
				t.Fatal("inspection ran with invalid configuration")
			}
		})
	}
}

func TestInspectHelpDoesNotRunCollection(t *testing.T) {
	t.Parallel()

	app := application{inspect: func(
		context.Context,
		inspectConfig,
	) (casebuilder.Assembly, error) {
		t.Fatal("inspection ran for help")
		return casebuilder.Assembly{}, nil
	}}
	var stderr bytes.Buffer
	err := app.run(
		context.Background(), []string{"inspect", "-h"}, strings.NewReader(""),
		&bytes.Buffer{}, &stderr,
	)
	if !errors.Is(err, flag.ErrHelp) || !strings.Contains(stderr.String(), "usage:") {
		t.Fatalf("error = %v, stderr = %q", err, stderr.String())
	}
}

func TestReadAPIKeyAcceptsOneOptionalLineEnding(t *testing.T) {
	t.Parallel()

	for _, content := range []string{"api-key", "api-key\n", "api-key\r\n"} {
		path := filepath.Join(t.TempDir(), "api-key")
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		key, err := readAPIKey("Radarr", path)
		if err != nil {
			t.Fatalf("content %q: %v", content, err)
		}
		if key != "api-key" {
			t.Fatalf("key = %q", key)
		}
	}
}

func TestReadAPIKeyRejectsInvalidCredentialWithoutEchoingIt(t *testing.T) {
	t.Parallel()

	secret := "do-not-echo-this"
	tests := [][]byte{
		nil,
		[]byte(" " + secret),
		[]byte(secret + "\n\n"),
		[]byte(secret + "\r"),
		[]byte(secret + "\x00"),
		bytes.Repeat([]byte("x"), maximumAPIKeySize+1),
	}
	for _, content := range tests {
		path := filepath.Join(t.TempDir(), "api-key")
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := readAPIKey("Radarr", path)
		if err == nil {
			t.Fatalf("content of length %d was accepted", len(content))
		}
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error echoed credential: %v", err)
		}
	}
}

func TestValidateLoopbackHTTP(t *testing.T) {
	t.Parallel()

	for _, endpoint := range []string{
		"http://127.0.0.1:7878",
		"http://[::1]:7878/radarr",
		"http://localhost.:7878",
	} {
		if err := validateLoopbackHTTP("service", endpoint); err != nil {
			t.Fatalf("endpoint %q: %v", endpoint, err)
		}
	}
	for _, endpoint := range []string{
		"https://localhost:7878",
		"http://service.example:7878",
		"http://key@localhost:7878",
		"http://localhost:7878?key=value",
		"http://secret%zz@localhost:7878",
	} {
		err := validateLoopbackHTTP("service", endpoint)
		if err == nil {
			t.Fatalf("endpoint %q was accepted", endpoint)
		}
		if strings.Contains(err.Error(), "secret") {
			t.Fatalf("error echoed URL credentials: %v", err)
		}
	}
}

func validInspectArguments(t *testing.T, output string) ([]string, string) {
	t.Helper()
	apiKeyFile := filepath.Join(t.TempDir(), "radarr-api-key")
	return []string{
		"inspect",
		"--radarr-url", "http://127.0.0.1:7878",
		"--radarr-api-key-file", apiKeyFile,
		"--transmission-url", "http://localhost:9091/transmission/rpc",
		"--sabnzbd-url", "http://localhost:8080/sabnzbd/api",
		"--sabnzbd-api-key-file", "/run/credentials/sabnzbd-api-key",
		"--worker-socket", "/run/radarr-repair/worker.sock",
		"--worker-root", "root:downloads=/data/downloads",
		"--worker-root", "root:archive=/data/archive",
		"--output", output,
		"--queue-id", "71",
		"--timeout", "45s",
		"--collection-timeout", "90s",
	}, apiKeyFile
}

func validInspectAllArguments(t *testing.T, outputDirectory string) ([]string, string) {
	t.Helper()
	apiKeyFile := filepath.Join(t.TempDir(), "radarr-api-key")
	return []string{
		"inspect",
		"--radarr-url", "http://127.0.0.1:7878",
		"--radarr-api-key-file", apiKeyFile,
		"--transmission-url", "http://localhost:9091/transmission/rpc",
		"--sabnzbd-url", "http://localhost:8080/sabnzbd/api",
		"--sabnzbd-api-key-file", "/run/credentials/sabnzbd-api-key",
		"--worker-socket", "/run/radarr-repair/worker.sock",
		"--worker-root", "root:downloads=/data/downloads",
		"--worker-root", "root:archive=/data/archive",
		"--all",
		"--output-directory", outputDirectory,
		"--timeout", "45s",
		"--collection-timeout", "90s",
	}, apiKeyFile
}

func replaceArgument(arguments []string, name, value string) []string {
	replaced := append([]string(nil), arguments...)
	for index := range replaced {
		if replaced[index] == name {
			replaced[index+1] = value
			return replaced
		}
	}
	panic("argument not found")
}
