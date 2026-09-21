package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	lidarrsource "github.com/booxter/nix-config/radarr-repair/internal/lidarr"
	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
)

const defaultRequestTimeout = 30 * time.Second

type config struct {
	LidarrURL    string
	APIKeyFile   string
	StateDir     string
	RequestLimit time.Duration
}

type report struct {
	Observed int
}

type observeFunc func(context.Context, config) (report, error)

type application struct {
	observe observeFunc
}

func run(ctx context.Context, arguments []string, stdout, stderr io.Writer) error {
	return application{observe: observeQueue}.run(ctx, arguments, stdout, stderr)
}

func (app application) run(
	ctx context.Context,
	arguments []string,
	stdout io.Writer,
	stderr io.Writer,
) error {
	flags := flag.NewFlagSet("lidarr-repair", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: lidarr-repair --lidarr-url URL --lidarr-api-key-file FILE --state-directory DIR",
		)
	}
	lidarrURL := flags.String("lidarr-url", "", "loopback Lidarr URL")
	apiKeyFile := flags.String("lidarr-api-key-file", "", "Lidarr API-key credential file")
	stateDirectory := flags.String("state-directory", "", "private controller state directory")
	timeout := flags.Duration("request-timeout", defaultRequestTimeout, "Lidarr request timeout")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("unexpected positional arguments")
	}
	configuration := config{
		LidarrURL: *lidarrURL, APIKeyFile: *apiKeyFile,
		StateDir: *stateDirectory, RequestLimit: *timeout,
	}
	if err := validateConfig(configuration); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if app.observe == nil {
		return fmt.Errorf("queue observer is not configured")
	}
	result, err := app.observe(ctx, configuration)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "observed=%d actions=0\n", result.Observed)
	return err
}

func validateConfig(configuration config) error {
	if err := servarr.ValidateLoopbackHTTP("Lidarr", configuration.LidarrURL); err != nil {
		return err
	}
	if !filepath.IsAbs(configuration.APIKeyFile) ||
		filepath.Clean(configuration.APIKeyFile) != configuration.APIKeyFile {
		return fmt.Errorf("Lidarr API-key file must be an absolute clean path")
	}
	if !filepath.IsAbs(configuration.StateDir) ||
		filepath.Clean(configuration.StateDir) != configuration.StateDir ||
		filepath.Dir(configuration.StateDir) == configuration.StateDir {
		return fmt.Errorf("state directory must be an absolute clean path")
	}
	if configuration.RequestLimit <= 0 {
		return fmt.Errorf("request timeout must be positive")
	}
	return nil
}

func observeQueue(ctx context.Context, configuration config) (report, error) {
	apiKey, err := servarr.ReadAPIKey("Lidarr", configuration.APIKeyFile)
	if err != nil {
		return report{}, err
	}
	transport, err := servarr.DirectHTTPTransport()
	if err != nil {
		return report{}, err
	}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   configuration.RequestLimit,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	client, err := lidarrsource.New(configuration.LidarrURL, apiKey, httpClient)
	if err != nil {
		return report{}, fmt.Errorf("configure Lidarr client: %w", err)
	}
	records, err := client.ReadQueue(ctx)
	if err != nil {
		return report{}, fmt.Errorf("observe Lidarr queue: %w", err)
	}
	return report{Observed: len(records)}, nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
