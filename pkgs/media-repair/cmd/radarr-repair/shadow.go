package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/mediaroot"
	"github.com/booxter/nix-config/media-repair/internal/plannerclient"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/radarrreview"
	"github.com/booxter/nix-config/media-repair/internal/review"
	shadowrunner "github.com/booxter/nix-config/media-repair/internal/shadow"
)

const (
	defaultPlannerTimeout = 10 * time.Minute
	defaultRetryInitial   = 5 * time.Minute
	defaultRetryMaximum   = 6 * time.Hour
)

type shadowConfig struct {
	RadarrURL          string
	RadarrAPIKeyFile   string
	TransmissionURL    string
	SABnzbdURL         string
	SABnzbdAPIKeyFile  string
	WorkerSocket       string
	WorkerRoots        map[string]string
	PlannerSocket      string
	StateDirectory     string
	MetricsFile        string
	RequestTimeout     time.Duration
	WorkerStageTimeout time.Duration
	CollectionTimeout  time.Duration
	PlannerTimeout     time.Duration
	RetryInitial       time.Duration
	RetryMaximum       time.Duration
	ReviewDirectory    string
}

type shadowFunc func(context.Context, shadowConfig) (shadowrunner.Report, error)

type shadowFlags struct {
	radarrURL          *string
	radarrAPIKeyFile   *string
	downloadSources    downloadSourceFlags
	workerSocket       *string
	workerRoots        mediaroot.Mappings
	plannerSocket      *string
	stateDirectory     *string
	metricsFile        *string
	requestTimeout     *time.Duration
	workerStageTimeout *time.Duration
	collectionTimeout  *time.Duration
	plannerTimeout     *time.Duration
	retryInitial       *time.Duration
	retryMaximum       *time.Duration
	reviewDirectory    *string
}

func addShadowFlags(flags *flag.FlagSet) shadowFlags {
	values := shadowFlags{
		radarrURL: flags.String("radarr-url", "", "loopback Radarr URL"),
		radarrAPIKeyFile: flags.String(
			"radarr-api-key-file", "", "Radarr API-key credential file",
		),
		downloadSources: addDownloadSourceFlags(flags),
		workerSocket:    flags.String("worker-socket", "", "media worker Unix socket"),
		workerRoots:     mediaroot.NewMappings(),
		plannerSocket:   flags.String("planner-socket", "", "repair planner Unix socket"),
		stateDirectory:  flags.String("state-directory", "", "private controller state directory"),
		metricsFile:     flags.String("metrics-file", "", "Prometheus textfile output"),
		requestTimeout: flags.Duration(
			"request-timeout", defaultInspectTimeout,
			"Radarr, download-client, and worker request timeout",
		),
		workerStageTimeout: flags.Duration(
			"worker-stage-timeout", defaultWorkerStageTimeout,
			"maximum duration of a worker media stage request",
		),
		collectionTimeout: flags.Duration(
			"collection-timeout", defaultCollectionTimeout,
			"per-case evidence-collection timeout",
		),
		plannerTimeout: flags.Duration(
			"planner-timeout", defaultPlannerTimeout, "planner request timeout",
		),
		retryInitial: flags.Duration(
			"retry-initial", defaultRetryInitial, "delay after the first planner failure",
		),
		retryMaximum: flags.Duration(
			"retry-maximum", defaultRetryMaximum, "maximum planner retry delay",
		),
		reviewDirectory: flags.String(
			"review-directory", "", "optional sanitized review snapshot directory",
		),
	}
	flags.Var(values.workerRoots, "worker-root", "worker media root as ID=PATH; repeatable")
	return values
}

func (values shadowFlags) Config() shadowConfig {
	return shadowConfig{
		RadarrURL:          *values.radarrURL,
		RadarrAPIKeyFile:   *values.radarrAPIKeyFile,
		TransmissionURL:    *values.downloadSources.transmissionURL,
		SABnzbdURL:         *values.downloadSources.sabnzbdURL,
		SABnzbdAPIKeyFile:  *values.downloadSources.sabnzbdAPIKeyFile,
		WorkerSocket:       *values.workerSocket,
		WorkerRoots:        values.workerRoots.Paths(),
		PlannerSocket:      *values.plannerSocket,
		StateDirectory:     *values.stateDirectory,
		MetricsFile:        *values.metricsFile,
		RequestTimeout:     *values.requestTimeout,
		WorkerStageTimeout: *values.workerStageTimeout,
		CollectionTimeout:  *values.collectionTimeout,
		PlannerTimeout:     *values.plannerTimeout,
		RetryInitial:       *values.retryInitial,
		RetryMaximum:       *values.retryMaximum,
		ReviewDirectory:    *values.reviewDirectory,
	}
}

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
				"[--sabnzbd-url URL --sabnzbd-api-key-file FILE] "+
				"--planner-socket PATH --state-directory DIR --metrics-file FILE",
		)
	}
	values := addShadowFlags(flags)
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("shadow accepts no positional arguments")
	}
	config := values.Config()
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
	metricsErr := shadowrunner.WriteMetrics(
		config.MetricsFile,
		report,
		runErr == nil,
		time.Now().UTC(),
	)
	outputErr := writeShadowSummary(stdout, report)
	return errors.Join(runErr, metricsErr, outputErr)
}

func writeShadowSummary(writer io.Writer, report shadowrunner.Report) error {
	_, err := fmt.Fprintf(
		writer,
		"observed=%d stored=%d superseded=%d submitted=%d decided=%d "+
			"already_decided=%d deferred=%d failed=%d rejected=%d\n",
		report.Observed,
		report.Stored,
		report.Superseded,
		report.Submitted,
		report.Decided,
		report.AlreadyDecided,
		report.Deferred,
		report.Failed,
		report.Rejected,
	)
	if err != nil {
		return err
	}
	for _, rejection := range report.Rejections {
		if _, err := fmt.Fprintf(
			writer,
			"rejected queue_id=%d reason=%s\n",
			rejection.QueueID,
			rejection.Reason,
		); err != nil {
			return err
		}
	}
	return nil
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
	if err := validateAbsolutePath("metrics file", config.MetricsFile, false); err != nil {
		return err
	}
	if config.ReviewDirectory != "" {
		if err := validateAbsolutePath("review directory", config.ReviewDirectory, false); err != nil {
			return err
		}
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
	report, runErr := runner.Run(ctx)
	publishErr := publishRadarrReview(config.ReviewDirectory, report, time.Now().UTC())
	return report, errors.Join(runErr, publishErr)
}

func publishRadarrReview(
	directory string,
	report shadowrunner.Report,
	generatedAt time.Time,
) error {
	if directory == "" {
		return nil
	}
	snapshot, err := radarrreview.Snapshot(report, generatedAt)
	if err != nil {
		return fmt.Errorf("build Radarr review snapshot: %w", err)
	}
	store, err := review.NewStore(directory)
	if err != nil {
		return fmt.Errorf("configure Radarr review store: %w", err)
	}
	if err := store.Publish(snapshot); err != nil {
		return fmt.Errorf("publish Radarr review snapshot: %w", err)
	}
	return nil
}

func (config shadowConfig) inspectionConfig() inspectConfig {
	return inspectConfig{
		RadarrURL:          config.RadarrURL,
		RadarrAPIKeyFile:   config.RadarrAPIKeyFile,
		TransmissionURL:    config.TransmissionURL,
		SABnzbdURL:         config.SABnzbdURL,
		SABnzbdAPIKeyFile:  config.SABnzbdAPIKeyFile,
		WorkerSocket:       config.WorkerSocket,
		WorkerRoots:        config.WorkerRoots,
		Timeout:            config.RequestTimeout,
		WorkerStageTimeout: config.WorkerStageTimeout,
		CollectionTimeout:  config.CollectionTimeout,
	}
}

func classifyPlannerFailure(err error) casestore.PlanningFailure {
	return planningrunner.ClassifyFailure(err)
}
