package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	filesource "github.com/booxter/nix-config/radarr-repair/internal/filesystem"
	"github.com/booxter/nix-config/radarr-repair/internal/inspection"
	"github.com/booxter/nix-config/radarr-repair/internal/mediaroot"
	radarrsource "github.com/booxter/nix-config/radarr-repair/internal/radarr"
	transmissionsource "github.com/booxter/nix-config/radarr-repair/internal/transmission"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
)

const (
	defaultInspectTimeout    = 30 * time.Second
	defaultCollectionTimeout = 2 * time.Minute
	maximumAPIKeySize        = 4 << 10
)

type inspectConfig struct {
	RadarrURL         string
	RadarrAPIKeyFile  string
	TransmissionURL   string
	WorkerSocket      string
	WorkerRoots       map[string]string
	Output            string
	QueueID           int64
	Timeout           time.Duration
	CollectionTimeout time.Duration
}

type inspectFunc func(context.Context, inspectConfig) (casebuilder.Assembly, error)

func (app application) runInspect(
	ctx context.Context,
	arguments []string,
	stdout, stderr io.Writer,
) error {
	flags := flag.NewFlagSet("inspect", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: radarr-repair inspect --radarr-url URL --radarr-api-key-file FILE "+
				"--transmission-url URL --worker-socket PATH --worker-root ID=PATH "+
				"--output FILE [--queue-id ID]",
		)
	}
	radarrURL := flags.String("radarr-url", "", "loopback Radarr URL")
	radarrAPIKeyFile := flags.String("radarr-api-key-file", "", "Radarr API-key credential file")
	transmissionURL := flags.String("transmission-url", "", "loopback Transmission RPC URL")
	workerSocket := flags.String("worker-socket", "", "media worker Unix socket")
	output := flags.String("output", "", "new output file, or - for standard output")
	queueID := flags.Int64("queue-id", 0, "specific Radarr queue record")
	timeout := flags.Duration("timeout", defaultInspectTimeout, "per-request timeout")
	collectionTimeout := flags.Duration(
		"collection-timeout",
		defaultCollectionTimeout,
		"total inspection evidence-collection timeout",
	)
	workerRoots := mediaroot.NewMappings()
	flags.Var(workerRoots, "worker-root", "worker media root as ID=PATH; repeatable")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("inspect accepts no positional arguments")
	}
	config := inspectConfig{
		RadarrURL:         *radarrURL,
		RadarrAPIKeyFile:  *radarrAPIKeyFile,
		TransmissionURL:   *transmissionURL,
		WorkerSocket:      *workerSocket,
		WorkerRoots:       workerRoots.Paths(),
		Output:            *output,
		QueueID:           *queueID,
		Timeout:           *timeout,
		CollectionTimeout: *collectionTimeout,
	}
	if err := validateInspectConfig(config); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := ensureOutputDoesNotExist(config.Output); err != nil {
		return err
	}
	if app.inspect == nil {
		return fmt.Errorf("inspection command is not configured")
	}
	assembly, err := app.inspect(ctx, config)
	if err != nil {
		return err
	}
	return writeInspectionOutput(config.Output, assembly.EncodedRequest, stdout)
}

func validateInspectConfig(config inspectConfig) error {
	if err := validateLoopbackHTTP("Radarr", config.RadarrURL); err != nil {
		return err
	}
	if err := validateLoopbackHTTP("Transmission", config.TransmissionURL); err != nil {
		return err
	}
	if config.RadarrAPIKeyFile == "" || strings.ContainsRune(config.RadarrAPIKeyFile, '\x00') ||
		!filepath.IsAbs(config.RadarrAPIKeyFile) ||
		filepath.Clean(config.RadarrAPIKeyFile) != config.RadarrAPIKeyFile {
		return fmt.Errorf("Radarr API-key file must be an absolute clean path")
	}
	if config.WorkerSocket == "" || strings.ContainsRune(config.WorkerSocket, '\x00') ||
		!filepath.IsAbs(config.WorkerSocket) ||
		filepath.Clean(config.WorkerSocket) != config.WorkerSocket {
		return fmt.Errorf("worker socket must be an absolute clean path")
	}
	if len(config.WorkerRoots) == 0 {
		return fmt.Errorf("at least one worker root is required")
	}
	if config.Output == "" {
		return fmt.Errorf("output is required")
	}
	if config.QueueID < 0 {
		return fmt.Errorf("queue ID must not be negative")
	}
	if config.Timeout <= 0 {
		return fmt.Errorf("request timeout must be positive")
	}
	if config.CollectionTimeout <= 0 {
		return fmt.Errorf("collection timeout must be positive")
	}
	return nil
}

func validateLoopbackHTTP(name, endpoint string) error {
	parsed, err := url.Parse(endpoint)
	if err != nil {
		return fmt.Errorf("%s URL is invalid", name)
	}
	if parsed.Scheme != "http" || parsed.Host == "" || parsed.User != nil ||
		parsed.RawQuery != "" || parsed.Fragment != "" || !isLoopbackHost(parsed.Hostname()) {
		return fmt.Errorf("%s URL must use loopback HTTP without credentials, query, or fragment", name)
	}
	return nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(strings.TrimSuffix(host, "."), "localhost") {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}

func inspectCase(ctx context.Context, config inspectConfig) (casebuilder.Assembly, error) {
	apiKey, err := readAPIKey(config.RadarrAPIKeyFile)
	if err != nil {
		return casebuilder.Assembly{}, err
	}
	transport, err := directHTTPTransport()
	if err != nil {
		return casebuilder.Assembly{}, err
	}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   config.Timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	radarrClient, err := radarrsource.New(config.RadarrURL, apiKey, httpClient)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("configure Radarr client: %w", err)
	}
	transmissionClient, err := transmissionsource.New(
		config.TransmissionURL,
		config.Timeout,
		httpClient,
	)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("configure Transmission client: %w", err)
	}
	probeClient, err := workerclient.New(config.WorkerSocket, config.WorkerRoots, config.Timeout)
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("configure media worker client: %w", err)
	}
	defer probeClient.Close()
	inspector, err := inspection.New(inspection.Dependencies{
		Clock:             wallClock{},
		Radarr:            radarrClient,
		Transmission:      transmissionClient,
		Files:             filesource.New(),
		Probes:            probeClient,
		CollectionTimeout: config.CollectionTimeout,
	})
	if err != nil {
		return casebuilder.Assembly{}, fmt.Errorf("configure inspector: %w", err)
	}
	return inspector.Inspect(ctx, inspection.Selection{QueueID: config.QueueID})
}

func directHTTPTransport() (*http.Transport, error) {
	base, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return nil, fmt.Errorf("default HTTP transport has an unexpected type")
	}
	transport := base.Clone()
	// Both HTTP services are required to be on loopback. Ignore proxy environment
	// variables so their requests and the Radarr API key cannot leave the host.
	transport.Proxy = nil
	return transport, nil
}

func readAPIKey(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open Radarr API-key file: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", fmt.Errorf("inspect Radarr API-key file: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("Radarr API-key file is not a regular file")
	}
	data, err := io.ReadAll(io.LimitReader(file, maximumAPIKeySize+1))
	if err != nil {
		return "", fmt.Errorf("read Radarr API-key file: %w", err)
	}
	if len(data) > maximumAPIKeySize {
		return "", fmt.Errorf("Radarr API-key file exceeds %d bytes", maximumAPIKeySize)
	}
	key := string(data)
	if strings.HasSuffix(key, "\n") {
		key = strings.TrimSuffix(key, "\n")
		key = strings.TrimSuffix(key, "\r")
	}
	if key == "" || !utf8.ValidString(key) || strings.TrimSpace(key) != key {
		return "", fmt.Errorf("Radarr API-key file contains an invalid credential")
	}
	for _, character := range key {
		if unicode.IsControl(character) {
			return "", fmt.Errorf("Radarr API-key file contains an invalid credential")
		}
	}
	return key, nil
}

func ensureOutputDoesNotExist(path string) error {
	if path == "-" {
		return nil
	}
	_, err := os.Lstat(path)
	switch {
	case err == nil:
		return fmt.Errorf("output %s already exists", path)
	case errors.Is(err, os.ErrNotExist):
		return nil
	default:
		return fmt.Errorf("inspect output %s: %w", path, err)
	}
}

func writeInspectionOutput(path string, data []byte, stdout io.Writer) error {
	if len(data) == 0 {
		return fmt.Errorf("assembled repair case is empty")
	}
	if path == "-" {
		return writeAll(stdout, data)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("create output %s: %w", path, err)
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.Remove(path)
		}
	}()
	if err := writeAll(file, data); err != nil {
		_ = file.Close()
		return fmt.Errorf("write output %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close output %s: %w", path, err)
	}
	complete = true
	return nil
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, err := writer.Write(data)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		data = data[written:]
	}
	return nil
}

type wallClock struct{}

func (wallClock) Now() time.Time {
	return time.Now()
}
