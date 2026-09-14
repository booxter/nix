package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/mediaroot"
	"github.com/booxter/nix-config/radarr-repair/internal/repairexecution"
)

const (
	defaultExecutionStabilization = 15 * time.Minute
	defaultImportPollInterval     = 2 * time.Second
)

type executeCaseConfig struct {
	RadarrURL         string
	RadarrAPIKeyFile  string
	TransmissionURL   string
	SABnzbdURL        string
	SABnzbdAPIKeyFile string
	WorkerSocket      string
	WorkerRoots       map[string]string
	StateDirectory    string
	CaseID            string
	RequestTimeout    time.Duration
	CollectionTimeout time.Duration
	Stabilization     time.Duration
	PollInterval      time.Duration
}

type executeCaseFunc func(
	context.Context,
	executeCaseConfig,
) (repairexecution.Result, error)

func (app application) runExecuteCase(
	ctx context.Context,
	arguments []string,
	stdout, stderr io.Writer,
) error {
	flags := flag.NewFlagSet("execute-case", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: radarr-repair execute-case --apply --case-id ID "+
				"--state-directory DIR --radarr-url URL --radarr-api-key-file FILE "+
				"--transmission-url URL --worker-socket PATH --worker-root ID=PATH "+
				"[--sabnzbd-url URL --sabnzbd-api-key-file FILE]",
		)
	}
	apply := flags.Bool("apply", false, "acknowledge that this command may modify Radarr and media storage")
	caseID := flags.String("case-id", "", "stored repair case ID")
	stateDirectory := flags.String("state-directory", "", "private controller state directory")
	radarrURL := flags.String("radarr-url", "", "loopback Radarr URL")
	radarrAPIKeyFile := flags.String(
		"radarr-api-key-file", "", "Radarr API-key credential file",
	)
	downloadFlags := addDownloadSourceFlags(flags)
	workerSocket := flags.String("worker-socket", "", "media worker Unix socket")
	requestTimeout := flags.Duration(
		"request-timeout", defaultInspectTimeout, "Radarr, download-client, and worker request timeout",
	)
	collectionTimeout := flags.Duration(
		"collection-timeout", defaultCollectionTimeout, "evidence-collection timeout",
	)
	stabilization := flags.Duration(
		"stabilization", defaultExecutionStabilization, "minimum unchanged import-pending age",
	)
	pollInterval := flags.Duration(
		"poll-interval", defaultImportPollInterval, "Radarr import status poll interval",
	)
	workerRoots := mediaroot.NewMappings()
	flags.Var(workerRoots, "worker-root", "worker media root as ID=PATH; repeatable")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("execute-case accepts no positional arguments")
	}
	config := executeCaseConfig{
		RadarrURL:         *radarrURL,
		RadarrAPIKeyFile:  *radarrAPIKeyFile,
		TransmissionURL:   *downloadFlags.transmissionURL,
		SABnzbdURL:        *downloadFlags.sabnzbdURL,
		SABnzbdAPIKeyFile: *downloadFlags.sabnzbdAPIKeyFile,
		WorkerSocket:      *workerSocket,
		WorkerRoots:       workerRoots.Paths(),
		StateDirectory:    *stateDirectory,
		CaseID:            *caseID,
		RequestTimeout:    *requestTimeout,
		CollectionTimeout: *collectionTimeout,
		Stabilization:     *stabilization,
		PollInterval:      *pollInterval,
	}
	if !*apply {
		return fmt.Errorf("--apply is required to execute a repair")
	}
	if err := validateExecuteCaseConfig(config); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if app.executeCase == nil {
		return fmt.Errorf("execute-case command is not configured")
	}
	result, runErr := app.executeCase(ctx, config)
	if emptyExecutionResult(result) {
		if runErr == nil {
			return fmt.Errorf("repair executor returned no result")
		}
		return runErr
	}
	return errors.Join(runErr, writeExecutionResult(stdout, result))
}

func validateExecuteCaseConfig(config executeCaseConfig) error {
	if !validExecutionCaseID(config.CaseID) {
		return fmt.Errorf("case ID must be sha256 followed by 64 lowercase hexadecimal digits")
	}
	if err := validateAbsolutePath("state directory", config.StateDirectory, false); err != nil {
		return err
	}
	if err := validateInspectionAccess(config.inspectionConfig()); err != nil {
		return err
	}
	if config.Stabilization <= 0 {
		return fmt.Errorf("stabilization interval must be positive")
	}
	if config.PollInterval <= 0 {
		return fmt.Errorf("poll interval must be positive")
	}
	return nil
}

func validExecutionCaseID(caseID string) bool {
	const prefix = "sha256:"
	if !strings.HasPrefix(caseID, prefix) || len(caseID) != len(prefix)+64 {
		return false
	}
	for _, character := range strings.TrimPrefix(caseID, prefix) {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}

func executeStoredCase(
	ctx context.Context,
	config executeCaseConfig,
) (repairexecution.Result, error) {
	store, err := casestore.New(config.StateDirectory)
	if err != nil {
		return repairexecution.Result{}, fmt.Errorf("configure case store: %w", err)
	}
	lease, err := store.AcquireExecution()
	if err != nil {
		return repairexecution.Result{}, fmt.Errorf("acquire repair execution lock: %w", err)
	}
	defer lease.Release()
	planned, err := store.GetPlannedCase(config.CaseID)
	if err != nil {
		return repairexecution.Result{}, fmt.Errorf("load planned repair case: %w", err)
	}
	executor, err := configureRepairExecutor(
		config.inspectionConfig(),
		store,
		config.Stabilization,
		config.PollInterval,
	)
	if err != nil {
		return repairexecution.Result{}, err
	}
	defer executor.Close()
	return executor.Execute(ctx, planned.Assembly, planned.Decision)
}

func (config executeCaseConfig) inspectionConfig() inspectConfig {
	return inspectConfig{
		RadarrURL:         config.RadarrURL,
		RadarrAPIKeyFile:  config.RadarrAPIKeyFile,
		TransmissionURL:   config.TransmissionURL,
		SABnzbdURL:        config.SABnzbdURL,
		SABnzbdAPIKeyFile: config.SABnzbdAPIKeyFile,
		WorkerSocket:      config.WorkerSocket,
		WorkerRoots:       config.WorkerRoots,
		Timeout:           config.RequestTimeout,
		CollectionTimeout: config.CollectionTimeout,
	}
}

func emptyExecutionResult(result repairexecution.Result) bool {
	return len(result.Check.Rejections) == 0 && result.ManualImport == nil && result.Join == nil
}

func writeExecutionResult(writer io.Writer, result repairexecution.Result) error {
	switch {
	case len(result.Check.Rejections) != 0:
		reasons := make([]string, len(result.Check.Rejections))
		for index, rejection := range result.Check.Rejections {
			reasons[index] = string(rejection.Reason)
		}
		_, err := fmt.Fprintf(
			writer,
			"action=none state=rejected reasons=%s resumed=%t\n",
			strings.Join(reasons, ","),
			result.Resumed,
		)
		return err
	case result.ManualImport != nil:
		_, err := fmt.Fprintf(
			writer,
			"action=manual_import_file_v1 state=%s resumed=%t\n",
			result.ManualImport.State,
			result.Resumed,
		)
		return err
	case result.Join != nil:
		_, err := fmt.Fprintf(
			writer,
			"action=join_parts_v1 state=%s resumed=%t\n",
			result.Join.State,
			result.Resumed,
		)
		return err
	default:
		return fmt.Errorf("repair executor returned no result")
	}
}
