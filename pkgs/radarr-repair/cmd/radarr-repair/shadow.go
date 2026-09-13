package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/mediaroot"
	"github.com/booxter/nix-config/radarr-repair/internal/plannerclient"
	shadowrunner "github.com/booxter/nix-config/radarr-repair/internal/shadow"
)

const (
	defaultPlannerTimeout = 10 * time.Minute
	defaultRetryInitial   = 5 * time.Minute
	defaultRetryMaximum   = 6 * time.Hour
)

type shadowConfig struct {
	RadarrURL         string
	RadarrAPIKeyFile  string
	TransmissionURL   string
	WorkerSocket      string
	WorkerRoots       map[string]string
	PlannerSocket     string
	StateDirectory    string
	RequestTimeout    time.Duration
	CollectionTimeout time.Duration
	PlannerTimeout    time.Duration
	RetryInitial      time.Duration
	RetryMaximum      time.Duration
}

type shadowFunc func(context.Context, shadowConfig) (shadowrunner.Report, error)

func (app application) runShadow(
	ctx context.Context,
	arguments []string,
	stdout, stderr io.Writer,
) error {
	flags := flag.NewFlagSet("shadow", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: radarr-repair shadow --radarr-url URL --radarr-api-key-file FILE "+
				"--transmission-url URL --worker-socket PATH --worker-root ID=PATH "+
				"--planner-socket PATH --state-directory DIR",
		)
	}
	radarrURL := flags.String("radarr-url", "", "loopback Radarr URL")
	radarrAPIKeyFile := flags.String(
		"radarr-api-key-file", "", "Radarr API-key credential file",
	)
	transmissionURL := flags.String("transmission-url", "", "loopback Transmission RPC URL")
	workerSocket := flags.String("worker-socket", "", "media worker Unix socket")
	plannerSocket := flags.String("planner-socket", "", "repair planner Unix socket")
	stateDirectory := flags.String("state-directory", "", "private controller state directory")
	requestTimeout := flags.Duration(
		"request-timeout", defaultInspectTimeout, "Radarr, Transmission, and worker request timeout",
	)
	collectionTimeout := flags.Duration(
		"collection-timeout", defaultCollectionTimeout, "per-case evidence-collection timeout",
	)
	plannerTimeout := flags.Duration(
		"planner-timeout", defaultPlannerTimeout, "planner request timeout",
	)
	retryInitial := flags.Duration(
		"retry-initial", defaultRetryInitial, "delay after the first planner failure",
	)
	retryMaximum := flags.Duration(
		"retry-maximum", defaultRetryMaximum, "maximum planner retry delay",
	)
	workerRoots := mediaroot.NewMappings()
	flags.Var(workerRoots, "worker-root", "worker media root as ID=PATH; repeatable")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("shadow accepts no positional arguments")
	}
	config := shadowConfig{
		RadarrURL:         *radarrURL,
		RadarrAPIKeyFile:  *radarrAPIKeyFile,
		TransmissionURL:   *transmissionURL,
		WorkerSocket:      *workerSocket,
		WorkerRoots:       workerRoots.Paths(),
		PlannerSocket:     *plannerSocket,
		StateDirectory:    *stateDirectory,
		RequestTimeout:    *requestTimeout,
		CollectionTimeout: *collectionTimeout,
		PlannerTimeout:    *plannerTimeout,
		RetryInitial:      *retryInitial,
		RetryMaximum:      *retryMaximum,
	}
	if err := validateShadowConfig(config); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if app.shadow == nil {
		return fmt.Errorf("shadow command is not configured")
	}
	report, runErr := app.shadow(ctx, config)
	_, outputErr := fmt.Fprintf(
		stdout,
		"observed=%d stored=%d submitted=%d decided=%d already_decided=%d deferred=%d failed=%d\n",
		report.Observed,
		report.Stored,
		report.Submitted,
		report.Decided,
		report.AlreadyDecided,
		report.Deferred,
		report.Failed,
	)
	return errors.Join(runErr, outputErr)
}

func validateShadowConfig(config shadowConfig) error {
	if err := validateInspectionAccess(config.inspectionConfig()); err != nil {
		return err
	}
	if err := validateAbsolutePath("planner socket", config.PlannerSocket, false); err != nil {
		return err
	}
	if err := validateAbsolutePath("state directory", config.StateDirectory, false); err != nil {
		return err
	}
	if config.PlannerTimeout <= 0 {
		return fmt.Errorf("planner timeout must be positive")
	}
	if config.RetryInitial <= 0 {
		return fmt.Errorf("initial planner retry delay must be positive")
	}
	if config.RetryMaximum < config.RetryInitial {
		return fmt.Errorf("maximum planner retry delay must not be shorter than the initial delay")
	}
	return nil
}

func runShadowOnce(
	ctx context.Context,
	config shadowConfig,
) (shadowrunner.Report, error) {
	inspector, closeInspector, err := configureInspector(config.inspectionConfig())
	if err != nil {
		return shadowrunner.Report{}, err
	}
	defer closeInspector()
	store, err := casestore.New(config.StateDirectory)
	if err != nil {
		return shadowrunner.Report{}, fmt.Errorf("configure case store: %w", err)
	}
	planner, err := plannerclient.New(config.PlannerSocket, config.PlannerTimeout)
	if err != nil {
		return shadowrunner.Report{}, fmt.Errorf("configure planner client: %w", err)
	}
	defer planner.Close()
	runner, err := shadowrunner.New(shadowrunner.Dependencies{
		Cases:           inspector,
		Store:           store,
		Planner:         planner,
		Clock:           wallClock{},
		ClassifyFailure: classifyPlannerFailure,
		Backoff: shadowrunner.Backoff{
			Initial: config.RetryInitial,
			Maximum: config.RetryMaximum,
		},
	})
	if err != nil {
		return shadowrunner.Report{}, fmt.Errorf("configure shadow runner: %w", err)
	}
	return runner.Run(ctx)
}

func (config shadowConfig) inspectionConfig() inspectConfig {
	return inspectConfig{
		RadarrURL:         config.RadarrURL,
		RadarrAPIKeyFile:  config.RadarrAPIKeyFile,
		TransmissionURL:   config.TransmissionURL,
		WorkerSocket:      config.WorkerSocket,
		WorkerRoots:       config.WorkerRoots,
		Timeout:           config.RequestTimeout,
		CollectionTimeout: config.CollectionTimeout,
	}
}

func classifyPlannerFailure(err error) casestore.PlanningFailure {
	var failure *plannerclient.Failure
	if !errors.As(err, &failure) {
		return casestore.PlanningFailure{Kind: casestore.PlanningFailureUnexpected}
	}
	switch failure.Kind {
	case plannerclient.FailureUnavailable:
		return casestore.PlanningFailure{Kind: casestore.PlanningFailureUnavailable}
	case plannerclient.FailureTimeout:
		return casestore.PlanningFailure{Kind: casestore.PlanningFailureTimeout}
	case plannerclient.FailureHTTP:
		return casestore.PlanningFailure{
			Kind: casestore.PlanningFailureHTTP, StatusCode: failure.StatusCode,
		}
	case plannerclient.FailureInvalidResponse:
		return casestore.PlanningFailure{Kind: casestore.PlanningFailureInvalidResult}
	default:
		return casestore.PlanningFailure{Kind: casestore.PlanningFailureUnexpected}
	}
}
