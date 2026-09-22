package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	downloadsources "github.com/booxter/nix-config/radarr-repair/internal/downloadsource"
	filesource "github.com/booxter/nix-config/radarr-repair/internal/filesystem"
	"github.com/booxter/nix-config/radarr-repair/internal/inspection"
	"github.com/booxter/nix-config/radarr-repair/internal/mediaroot"
	radarrsource "github.com/booxter/nix-config/radarr-repair/internal/radarr"
	sabnzbdsource "github.com/booxter/nix-config/radarr-repair/internal/sabnzbd"
	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
	transmissionsource "github.com/booxter/nix-config/radarr-repair/internal/transmission"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
)

const (
	defaultInspectTimeout     = 30 * time.Second
	defaultCollectionTimeout  = 2 * time.Minute
	defaultWorkerStageTimeout = 31 * time.Minute
	maximumAPIKeySize         = servarr.MaximumAPIKeySize
)

type inspectConfig struct {
	RadarrURL          string
	RadarrAPIKeyFile   string
	TransmissionURL    string
	SABnzbdURL         string
	SABnzbdAPIKeyFile  string
	WorkerSocket       string
	WorkerRoots        map[string]string
	Output             string
	OutputDirectory    string
	QueueID            int64
	All                bool
	Timeout            time.Duration
	WorkerStageTimeout time.Duration
	CollectionTimeout  time.Duration
}

type inspectFunc func(context.Context, inspectConfig) (casebuilder.Assembly, error)
type inspectAllFunc func(context.Context, inspectConfig) ([]casebuilder.Assembly, error)

type downloadSourceFlags struct {
	transmissionURL   *string
	sabnzbdURL        *string
	sabnzbdAPIKeyFile *string
}

func addDownloadSourceFlags(flags *flag.FlagSet) downloadSourceFlags {
	return downloadSourceFlags{
		transmissionURL: flags.String(
			"transmission-url", "", "loopback Transmission RPC URL",
		),
		sabnzbdURL: flags.String(
			"sabnzbd-url", "", "loopback SABnzbd API URL",
		),
		sabnzbdAPIKeyFile: flags.String(
			"sabnzbd-api-key-file", "", "SABnzbd API-key credential file",
		),
	}
}

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
				"[--sabnzbd-url URL --sabnzbd-api-key-file FILE] "+
				"(--output FILE [--queue-id ID] | --all --output-directory DIR)",
		)
	}
	radarrURL := flags.String("radarr-url", "", "loopback Radarr URL")
	radarrAPIKeyFile := flags.String("radarr-api-key-file", "", "Radarr API-key credential file")
	downloadFlags := addDownloadSourceFlags(flags)
	workerSocket := flags.String("worker-socket", "", "media worker Unix socket")
	output := flags.String("output", "", "new output file, or - for standard output")
	outputDirectory := flags.String(
		"output-directory",
		"",
		"new private directory for cases captured with --all",
	)
	queueID := flags.Int64("queue-id", 0, "specific Radarr queue record")
	all := flags.Bool("all", false, "inspect every eligible Radarr queue record")
	timeout := flags.Duration("timeout", defaultInspectTimeout, "per-request timeout")
	collectionTimeout := flags.Duration(
		"collection-timeout",
		defaultCollectionTimeout,
		"per-case evidence-collection timeout",
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
		TransmissionURL:   *downloadFlags.transmissionURL,
		SABnzbdURL:        *downloadFlags.sabnzbdURL,
		SABnzbdAPIKeyFile: *downloadFlags.sabnzbdAPIKeyFile,
		WorkerSocket:      *workerSocket,
		WorkerRoots:       workerRoots.Paths(),
		Output:            *output,
		OutputDirectory:   *outputDirectory,
		QueueID:           *queueID,
		All:               *all,
		Timeout:           *timeout,
		CollectionTimeout: *collectionTimeout,
	}
	if err := validateInspectConfig(config); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	outputPath := config.Output
	if config.All {
		outputPath = config.OutputDirectory
	}
	if err := ensureOutputDoesNotExist(outputPath); err != nil {
		return err
	}
	if config.All {
		if app.inspectAll == nil {
			return fmt.Errorf("bulk inspection command is not configured")
		}
		assemblies, err := app.inspectAll(ctx, config)
		if err != nil {
			return err
		}
		if err := writeInspectionDirectory(config.OutputDirectory, assemblies); err != nil {
			return err
		}
		_, err = fmt.Fprintf(stdout, "captured %d repair cases\n", len(assemblies))
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
	if err := validateInspectionAccess(config); err != nil {
		return err
	}
	if config.QueueID < 0 {
		return fmt.Errorf("queue ID must not be negative")
	}
	if config.All {
		if config.QueueID != 0 || config.Output != "" || config.OutputDirectory == "" {
			return fmt.Errorf("--all requires --output-directory and cannot use --output or --queue-id")
		}
		if !filepath.IsAbs(config.OutputDirectory) ||
			filepath.Clean(config.OutputDirectory) != config.OutputDirectory {
			return fmt.Errorf("output directory must be an absolute clean path")
		}
	} else if config.Output == "" || config.OutputDirectory != "" {
		return fmt.Errorf("--output is required without --all and --output-directory is not allowed")
	}
	return nil
}

func validateInspectionAccess(config inspectConfig) error {
	if err := validateLoopbackHTTP("Radarr", config.RadarrURL); err != nil {
		return err
	}
	if err := validateLoopbackHTTP("Transmission", config.TransmissionURL); err != nil {
		return err
	}
	sabnzbdURLSet := config.SABnzbdURL != ""
	sabnzbdKeySet := config.SABnzbdAPIKeyFile != ""
	if sabnzbdURLSet != sabnzbdKeySet {
		return fmt.Errorf("SABnzbd URL and API-key file must be configured together")
	}
	if sabnzbdURLSet {
		if err := validateLoopbackHTTP("SABnzbd", config.SABnzbdURL); err != nil {
			return err
		}
		if err := validateAbsolutePath(
			"SABnzbd API-key file", config.SABnzbdAPIKeyFile, true,
		); err != nil {
			return err
		}
	}
	if err := validateAbsolutePath("Radarr API-key file", config.RadarrAPIKeyFile, true); err != nil {
		return err
	}
	if err := validateAbsolutePath("worker socket", config.WorkerSocket, true); err != nil {
		return err
	}
	if len(config.WorkerRoots) == 0 {
		return fmt.Errorf("at least one worker root is required")
	}
	if config.Timeout <= 0 {
		return fmt.Errorf("request timeout must be positive")
	}
	if config.CollectionTimeout <= 0 {
		return fmt.Errorf("collection timeout must be positive")
	}
	return nil
}

func validateAbsolutePath(name, path string, allowFilesystemRoot bool) error {
	if path == "" || strings.ContainsRune(path, '\x00') ||
		!filepath.IsAbs(path) || filepath.Clean(path) != path ||
		(!allowFilesystemRoot && filepath.Dir(path) == path) {
		return fmt.Errorf("%s must be an absolute clean path", name)
	}
	return nil
}

func validateLoopbackHTTP(name, endpoint string) error {
	return servarr.ValidateLoopbackHTTP(name, endpoint)
}

func inspectCase(ctx context.Context, config inspectConfig) (casebuilder.Assembly, error) {
	inspector, closeInspector, err := configureInspector(config)
	if err != nil {
		return casebuilder.Assembly{}, err
	}
	defer closeInspector()
	return inspector.Inspect(ctx, inspection.Selection{QueueID: config.QueueID})
}

func inspectAllCases(ctx context.Context, config inspectConfig) ([]casebuilder.Assembly, error) {
	inspector, closeInspector, err := configureInspector(config)
	if err != nil {
		return nil, err
	}
	defer closeInspector()
	result, err := inspector.InspectAll(ctx)
	return result.Assemblies, err
}

func configureInspector(config inspectConfig) (*inspection.Inspector, func(), error) {
	access, err := configureControllerAccess(config)
	if err != nil {
		return nil, nil, err
	}
	return access.inspector, access.Close, nil
}

type controllerAccess struct {
	inspector *inspection.Inspector
	radarr    *radarrsource.Client
	worker    *workerclient.Client
	transport *http.Transport
}

func configureControllerAccess(config inspectConfig) (*controllerAccess, error) {
	apiKey, err := readAPIKey("Radarr", config.RadarrAPIKeyFile)
	if err != nil {
		return nil, err
	}
	transport, err := directHTTPTransport()
	if err != nil {
		return nil, err
	}
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   config.Timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	radarrClient, err := radarrsource.New(config.RadarrURL, apiKey, httpClient)
	if err != nil {
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("configure Radarr client: %w", err)
	}
	transmissionClient, err := transmissionsource.New(
		config.TransmissionURL,
		config.Timeout,
		httpClient,
	)
	if err != nil {
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("configure Transmission client: %w", err)
	}
	registrations := []downloadsources.Registration{{
		Protocol: "torrent", ClientName: "Transmission", Reader: transmissionClient,
	}}
	if config.SABnzbdURL != "" {
		sabnzbdAPIKey, keyErr := readAPIKey("SABnzbd", config.SABnzbdAPIKeyFile)
		if keyErr != nil {
			transport.CloseIdleConnections()
			return nil, keyErr
		}
		sabnzbdClient, clientErr := sabnzbdsource.New(
			config.SABnzbdURL,
			sabnzbdAPIKey,
			config.Timeout,
			httpClient,
		)
		if clientErr != nil {
			transport.CloseIdleConnections()
			return nil, fmt.Errorf("configure SABnzbd client: %w", clientErr)
		}
		registrations = append(registrations, downloadsources.Registration{
			Protocol: "usenet", ClientName: "SABnzbd", Reader: sabnzbdClient,
		})
	}
	downloads, err := downloadsources.New(registrations...)
	if err != nil {
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("configure download sources: %w", err)
	}
	stageTimeout := config.WorkerStageTimeout
	if stageTimeout == 0 {
		stageTimeout = defaultWorkerStageTimeout
	}
	probeClient, err := workerclient.New(
		config.WorkerSocket, config.WorkerRoots, config.Timeout, stageTimeout,
	)
	if err != nil {
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("configure media worker client: %w", err)
	}
	inspector, err := inspection.New(inspection.Dependencies{
		Clock:             wallClock{},
		Radarr:            radarrClient,
		Downloads:         downloads,
		Files:             filesource.New(),
		Probes:            probeClient,
		Playlists:         probeClient,
		DVDs:              probeClient,
		CollectionTimeout: config.CollectionTimeout,
	})
	if err != nil {
		probeClient.Close()
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("configure inspector: %w", err)
	}
	return &controllerAccess{
		inspector: inspector,
		radarr:    radarrClient,
		worker:    probeClient,
		transport: transport,
	}, nil
}

func (access *controllerAccess) Close() {
	if access == nil {
		return
	}
	access.worker.Close()
	access.transport.CloseIdleConnections()
}

func directHTTPTransport() (*http.Transport, error) {
	return servarr.DirectHTTPTransport()
}

func readAPIKey(service, path string) (string, error) {
	return servarr.ReadAPIKey(service, path)
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

func writeInspectionDirectory(path string, assemblies []casebuilder.Assembly) error {
	if len(assemblies) == 0 {
		return fmt.Errorf("bulk inspection produced no repair cases")
	}
	filenames := make([]string, len(assemblies))
	seen := make(map[string]struct{}, len(assemblies))
	for index, assembly := range assemblies {
		if len(assembly.EncodedRequest) == 0 {
			return fmt.Errorf("assembled repair case %d is empty", index)
		}
		filename, err := inspectionFilename(assembly.Request.CaseID)
		if err != nil {
			return err
		}
		if _, duplicate := seen[filename]; duplicate {
			return fmt.Errorf("bulk inspection produced duplicate case ID %q", assembly.Request.CaseID)
		}
		seen[filename] = struct{}{}
		filenames[index] = filename
	}

	if err := os.Mkdir(path, 0o700); err != nil {
		return fmt.Errorf("create output directory %s: %w", path, err)
	}
	written := make([]string, 0, len(assemblies))
	complete := false
	defer func() {
		if complete {
			return
		}
		for _, output := range written {
			_ = os.Remove(output)
		}
		_ = os.Remove(path)
	}()

	for index, assembly := range assemblies {
		output := filepath.Join(path, filenames[index])
		if err := writeInspectionOutput(output, assembly.EncodedRequest, io.Discard); err != nil {
			return err
		}
		written = append(written, output)
	}
	complete = true
	return nil
}

func inspectionFilename(caseID string) (string, error) {
	const prefix = "sha256:"
	if !strings.HasPrefix(caseID, prefix) || len(caseID) != len(prefix)+64 {
		return "", fmt.Errorf("assembled repair case has invalid case ID %q", caseID)
	}
	digest := strings.TrimPrefix(caseID, prefix)
	for _, character := range digest {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return "", fmt.Errorf("assembled repair case has invalid case ID %q", caseID)
		}
	}
	return digest + ".json", nil
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
