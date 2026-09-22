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
	"github.com/booxter/nix-config/radarr-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/radarr-repair/internal/mediaroot"
	"github.com/booxter/nix-config/radarr-repair/internal/plannerclient"
	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
)

const (
	defaultRequestTimeout = 30 * time.Second
	defaultStageTimeout   = 30 * time.Minute
	defaultPlannerTimeout = 21 * time.Minute
)

type config struct {
	LidarrURL     string
	APIKeyFile    string
	StateDir      string
	WorkerSocket  string
	WorkerRoots   map[string]string
	PlannerSocket string
	RequestLimit  time.Duration
	StageLimit    time.Duration
	PlannerLimit  time.Duration
}

type report struct {
	Observed   int
	Candidates int
	Planned    int
	Cached     int
	NoRepair   int
}

type observeFunc func(context.Context, config) (report, error)

type application struct {
	observe observeFunc
}

func run(ctx context.Context, arguments []string, stdout, stderr io.Writer) error {
	return application{observe: runShadow}.run(ctx, arguments, stdout, stderr)
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
			"usage: lidarr-repair --lidarr-url URL --lidarr-api-key-file FILE "+
				"--worker-socket PATH --worker-root ID=PATH --planner-socket PATH "+
				"--state-directory DIR",
		)
	}
	lidarrURL := flags.String("lidarr-url", "", "loopback Lidarr URL")
	apiKeyFile := flags.String("lidarr-api-key-file", "", "Lidarr API-key credential file")
	stateDirectory := flags.String("state-directory", "", "private controller state directory")
	workerSocket := flags.String("worker-socket", "", "media worker Unix socket")
	workerRoots := mediaroot.NewMappings()
	flags.Var(workerRoots, "worker-root", "worker media root as ID=PATH; repeatable")
	plannerSocket := flags.String("planner-socket", "", "repair planner Unix socket")
	timeout := flags.Duration("request-timeout", defaultRequestTimeout, "Lidarr request timeout")
	stageTimeout := flags.Duration("worker-stage-timeout", defaultStageTimeout, "worker stage timeout")
	plannerTimeout := flags.Duration("planner-timeout", defaultPlannerTimeout, "planner request timeout")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("unexpected positional arguments")
	}
	configuration := config{
		LidarrURL: *lidarrURL, APIKeyFile: *apiKeyFile,
		StateDir: *stateDirectory, WorkerSocket: *workerSocket,
		WorkerRoots: workerRoots.Paths(), PlannerSocket: *plannerSocket,
		RequestLimit: *timeout, StageLimit: *stageTimeout, PlannerLimit: *plannerTimeout,
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
	_, err = fmt.Fprintf(
		stdout,
		"observed=%d candidates=%d planned=%d cached=%d no_repair=%d actions=0\n",
		result.Observed, result.Candidates, result.Planned, result.Cached, result.NoRepair,
	)
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
	for name, path := range map[string]string{
		"worker socket":  configuration.WorkerSocket,
		"planner socket": configuration.PlannerSocket,
	} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path {
			return fmt.Errorf("%s must be an absolute clean path", name)
		}
	}
	if len(configuration.WorkerRoots) == 0 {
		return fmt.Errorf("at least one worker root is required")
	}
	if configuration.RequestLimit <= 0 || configuration.StageLimit <= 0 ||
		configuration.PlannerLimit <= 0 {
		return fmt.Errorf("request timeouts must be positive")
	}
	return nil
}

func runShadow(ctx context.Context, configuration config) (report, error) {
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
	worker, err := workerclient.New(
		configuration.WorkerSocket, configuration.WorkerRoots,
		configuration.RequestLimit, configuration.StageLimit,
	)
	if err != nil {
		return report{}, fmt.Errorf("configure media worker client: %w", err)
	}
	defer worker.Close()
	planner, err := plannerclient.New(configuration.PlannerSocket, configuration.PlannerLimit)
	if err != nil {
		return report{}, fmt.Errorf("configure repair planner client: %w", err)
	}
	defer planner.Close()
	store, err := lidarrrepair.NewStore(configuration.StateDir)
	if err != nil {
		return report{}, err
	}
	runner, err := lidarrrepair.NewRunner(client, worker, planner, store)
	if err != nil {
		return report{}, err
	}
	result, err := runner.Run(ctx)
	return report{
		Observed: result.Observed, Candidates: result.Candidates,
		Planned: result.Planned, Cached: result.Cached, NoRepair: result.NoRepair,
	}, err
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
