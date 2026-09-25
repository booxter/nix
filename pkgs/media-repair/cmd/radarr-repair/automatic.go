package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/applyrunner"
	"github.com/booxter/nix-config/media-repair/internal/applyselection"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
	radarrsource "github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	shadowrunner "github.com/booxter/nix-config/media-repair/internal/shadow"
)

const automaticRepairLimit = 1

type automaticConfig struct {
	Shadow                 shadowConfig
	AllowedActions         map[contracts.DecisionAction]bool
	AllowedDownloadClients map[controller.DownloadClient]bool
	KillSwitchFile         string
	Stabilization          time.Duration
	PollInterval           time.Duration
	FinalizeStale          bool
}

type automaticReport struct {
	Shadow          shadowrunner.Report
	Apply           applyrunner.Report
	ShadowSucceeded bool
	ApplyDisabled   bool
	Finalization    queuefinalize.Report
	FinalizeEnabled bool
}

type automaticFunc func(context.Context, automaticConfig) (automaticReport, error)

type applyGuard interface {
	Disabled(string) (bool, error)
}

type automaticApplyFunc func(
	context.Context,
	automaticConfig,
	[]casestore.PlannedCase,
) (applyrunner.Report, error)

type automaticFinalizeFunc func(context.Context, automaticConfig) (queuefinalize.Report, error)

type automaticDependencies struct {
	shadow   shadowFunc
	guard    applyGuard
	apply    automaticApplyFunc
	finalize automaticFinalizeFunc
}

type allowedActionsValue struct {
	actions map[contracts.DecisionAction]bool
}

type allowedDownloadClientsValue struct {
	clients map[controller.DownloadClient]bool
}

func (value *allowedDownloadClientsValue) String() string {
	return ""
}

func (value *allowedDownloadClientsValue) Set(raw string) error {
	client := controller.DownloadClient(raw)
	switch client {
	case controller.DownloadClientTransmission, controller.DownloadClientSABnzbd:
		value.clients[client] = true
		return nil
	default:
		return fmt.Errorf("download client %q cannot be allowed for automatic repair", raw)
	}
}

func (value *allowedActionsValue) String() string {
	return ""
}

func (value *allowedActionsValue) Set(raw string) error {
	action := contracts.DecisionAction(raw)
	switch action {
	case contracts.ActionJoinParts, contracts.ActionManualImportFile,
		contracts.ActionRemuxBluray, contracts.ActionRemuxDVD:
		value.actions[action] = true
		return nil
	default:
		return fmt.Errorf("action %q cannot be allowed for automatic repair", raw)
	}
}

func (app application) runAutomatic(
	ctx context.Context,
	arguments []string,
	stdout, stderr io.Writer,
) error {
	flags := flag.NewFlagSet("run", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: radarr-repair run --apply --allow-action ACTION "+
				"--allow-download-client CLIENT "+
				"--kill-switch-file FILE --radarr-url URL --radarr-api-key-file FILE "+
				"--transmission-url URL --worker-socket PATH --worker-root ID=PATH "+
				"[--sabnzbd-url URL --sabnzbd-api-key-file FILE] "+
				"--planner-socket PATH --state-directory DIR --metrics-file FILE",
		)
	}
	shadowValues := addShadowFlags(flags)
	apply := flags.Bool("apply", false, "acknowledge that one permitted repair may be applied")
	allowed := allowedActionsValue{actions: make(map[contracts.DecisionAction]bool)}
	flags.Var(&allowed, "allow-action", "repair action to permit; repeatable")
	allowedClients := allowedDownloadClientsValue{clients: make(map[controller.DownloadClient]bool)}
	flags.Var(
		&allowedClients,
		"allow-download-client",
		"download client whose cases may be repaired; repeatable",
	)
	killSwitchFile := flags.String(
		"kill-switch-file", "", "existing filesystem entry disables repair application",
	)
	stabilization := flags.Duration(
		"stabilization", defaultExecutionStabilization,
		"time an imported result must remain stable",
	)
	pollInterval := flags.Duration(
		"poll-interval", defaultImportPollInterval, "Radarr import confirmation poll interval",
	)
	finalizeStale := flags.Bool(
		"finalize-stale-queue", false,
		"remove tracking for completed warnings whose movie already has a file",
	)
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("run accepts no positional arguments")
	}
	config := automaticConfig{
		Shadow:                 shadowValues.Config(),
		AllowedActions:         allowed.actions,
		AllowedDownloadClients: allowedClients.clients,
		KillSwitchFile:         *killSwitchFile,
		Stabilization:          *stabilization,
		PollInterval:           *pollInterval,
		FinalizeStale:          *finalizeStale,
	}
	if err := validateAutomaticConfig(config, *apply); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if app.automatic == nil {
		return fmt.Errorf("run command is not configured")
	}
	report, runErr := app.automatic(ctx, config)
	metricsErr := shadowrunner.WriteMetrics(
		config.Shadow.MetricsFile,
		report.Shadow,
		report.ShadowSucceeded,
		time.Now().UTC(),
		automaticMetrics(report, runErr == nil)...,
	)
	outputErr := writeAutomaticSummary(stdout, report)
	return errors.Join(runErr, metricsErr, outputErr)
}

func validateAutomaticConfig(config automaticConfig, apply bool) error {
	if err := validateShadowConfig(config.Shadow); err != nil {
		return err
	}
	if !apply {
		return fmt.Errorf("--apply is required")
	}
	if len(config.AllowedActions) == 0 {
		return fmt.Errorf("at least one --allow-action is required")
	}
	if len(config.AllowedDownloadClients) == 0 {
		return fmt.Errorf("at least one --allow-download-client is required")
	}
	if err := validateAbsolutePath("kill-switch file", config.KillSwitchFile, false); err != nil {
		return err
	}
	if config.Stabilization <= 0 {
		return fmt.Errorf("stabilization must be positive")
	}
	if config.PollInterval <= 0 {
		return fmt.Errorf("poll interval must be positive")
	}
	return nil
}

func writeAutomaticSummary(writer io.Writer, report automaticReport) error {
	if err := writeShadowSummary(writer, report.Shadow); err != nil {
		return err
	}
	if !report.ShadowSucceeded {
		return nil
	}
	if report.FinalizeEnabled {
		if _, err := fmt.Fprintf(
			writer, "queue_finalized=%d queue_reconciled=%d\n",
			report.Finalization.Finalized, report.Finalization.Reconciled,
		); err != nil {
			return err
		}
	}
	if report.ApplyDisabled {
		_, err := fmt.Fprintln(writer, "apply=disabled")
		return err
	}
	if len(report.Apply.Executions) == 0 {
		_, err := fmt.Fprintf(
			writer,
			"apply=none permitted=%d finished=%d selected=%d\n",
			report.Apply.Permitted,
			report.Apply.Finished,
			report.Apply.Selected,
		)
		return err
	}
	for _, execution := range report.Apply.Executions {
		var err error
		if len(execution.Result.Check.Rejections) != 0 {
			err = writeAutomaticRejection(writer, execution)
		} else {
			err = writeAutomaticExecution(writer, execution)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func writeAutomaticRejection(writer io.Writer, execution applyrunner.CaseResult) error {
	rejection := execution.Result.Check.Rejections[0]
	if rejection.Stabilization != nil {
		assessment := rejection.Stabilization
		_, err := fmt.Fprintf(
			writer,
			"apply=precondition_rejected case_id=%s action=%s reason=%s "+
				"observed_at=%s checked_at=%s required_age=%s actual_age=%s\n",
			execution.CaseID,
			execution.Action,
			rejection.Reason,
			assessment.ObservedAt.UTC().Format(time.RFC3339Nano),
			assessment.CheckedAt.UTC().Format(time.RFC3339Nano),
			assessment.RequiredAge,
			assessment.ActualAge,
		)
		return err
	}
	if rejection.DecisionReason != "" {
		_, err := fmt.Fprintf(
			writer,
			"apply=precondition_rejected case_id=%s action=%s reason=%s decision_reason=%s\n",
			execution.CaseID,
			execution.Action,
			rejection.Reason,
			rejection.DecisionReason,
		)
		return err
	}
	_, err := fmt.Fprintf(
		writer,
		"apply=precondition_rejected case_id=%s action=%s reason=%s\n",
		execution.CaseID,
		execution.Action,
		rejection.Reason,
	)
	return err
}

func writeAutomaticExecution(writer io.Writer, execution applyrunner.CaseResult) error {
	result := execution.Result
	switch {
	case result.ManualImport != nil:
		if result.ManualImport.CommandID == nil {
			_, err := fmt.Fprintf(
				writer,
				"apply=completed case_id=%s action=%s state=%s\n",
				execution.CaseID,
				execution.Action,
				result.ManualImport.State,
			)
			return err
		}
		_, err := fmt.Fprintf(
			writer,
			"apply=completed case_id=%s action=%s state=%s command_id=%d\n",
			execution.CaseID,
			execution.Action,
			result.ManualImport.State,
			*result.ManualImport.CommandID,
		)
		return err
	case result.Join != nil:
		_, err := fmt.Fprintf(
			writer,
			"apply=completed case_id=%s action=%s state=%s execution_id=%s\n",
			execution.CaseID,
			execution.Action,
			result.Join.State,
			result.Join.ExecutionID,
		)
		return err
	case result.Remux != nil:
		_, err := fmt.Fprintf(
			writer,
			"apply=completed case_id=%s action=%s state=%s execution_id=%s\n",
			execution.CaseID,
			execution.Action,
			result.Remux.State,
			result.Remux.ExecutionID,
		)
		return err
	default:
		_, err := fmt.Fprintf(
			writer,
			"apply=executor_error case_id=%s action=%s\n",
			execution.CaseID,
			execution.Action,
		)
		return err
	}
}

func runAutomaticOnce(ctx context.Context, config automaticConfig) (automaticReport, error) {
	return runAutomaticWith(ctx, config, automaticDependencies{
		shadow:   runShadowOnce,
		guard:    filesystemApplyGuard{},
		apply:    applyCurrentCases,
		finalize: finalizeRadarrQueue,
	})
}

func runAutomaticWith(
	ctx context.Context,
	config automaticConfig,
	dependencies automaticDependencies,
) (automaticReport, error) {
	report := automaticReport{FinalizeEnabled: config.FinalizeStale}
	shadowReport, err := dependencies.shadow(ctx, config.Shadow)
	report.Shadow = shadowReport
	if err != nil {
		return report, err
	}
	report.ShadowSucceeded = true
	disabled, err := dependencies.guard.Disabled(config.KillSwitchFile)
	if err != nil {
		report.ApplyDisabled = true
		return report, fmt.Errorf("inspect repair kill switch: %w", err)
	}
	if disabled {
		report.ApplyDisabled = true
		return report, nil
	}
	report.Apply, err = dependencies.apply(ctx, config, shadowReport.PlannedCases)
	if err != nil || !config.FinalizeStale {
		return report, err
	}
	if dependencies.finalize == nil {
		return report, fmt.Errorf("queue finalizer is not configured")
	}
	report.Finalization, err = dependencies.finalize(ctx, config)
	return report, err
}

func finalizeRadarrQueue(
	ctx context.Context,
	config automaticConfig,
) (queuefinalize.Report, error) {
	apiKey, err := servarr.ReadAPIKey("Radarr", config.Shadow.RadarrAPIKeyFile)
	if err != nil {
		return queuefinalize.Report{}, err
	}
	transport, err := servarr.DirectHTTPTransport()
	if err != nil {
		return queuefinalize.Report{}, err
	}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   config.Shadow.RequestTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	client, err := radarrsource.New(config.Shadow.RadarrURL, apiKey, httpClient)
	if err != nil {
		return queuefinalize.Report{}, fmt.Errorf("configure Radarr queue finalizer: %w", err)
	}
	candidates, err := radarrsource.FinalizationCandidates(ctx, client)
	if err != nil {
		return queuefinalize.Report{}, err
	}
	finalizer, err := queuefinalize.New(queuefinalize.Dependencies{
		Service: "Radarr", StateDirectory: config.Shadow.StateDirectory,
		ReadQueue: func(ctx context.Context) ([]queuefinalize.Entry, error) {
			records, err := client.ReadQueue(ctx)
			if err != nil {
				return nil, err
			}
			entries := make([]queuefinalize.Entry, len(records))
			for index, record := range records {
				entries[index] = radarrsource.FinalizationEntry(record)
			}
			return entries, nil
		},
		Remove: client.FinalizeQueue,
		Clock:  wallClock{},
	})
	if err != nil {
		return queuefinalize.Report{}, fmt.Errorf("configure Radarr queue finalizer: %w", err)
	}
	return finalizer.Run(ctx, candidates, 1)
}

type filesystemApplyGuard struct{}

func (filesystemApplyGuard) Disabled(path string) (bool, error) {
	_, err := os.Lstat(path)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return true, err
}

type caseStoreExecutionLocker struct {
	store *casestore.Store
}

func (locker caseStoreExecutionLocker) Acquire() (applyrunner.Lease, error) {
	return locker.store.AcquireExecution()
}

func applyCurrentCases(
	ctx context.Context,
	config automaticConfig,
	planned []casestore.PlannedCase,
) (applyrunner.Report, error) {
	store, err := casestore.New(config.Shadow.StateDirectory)
	if err != nil {
		return applyrunner.Report{}, fmt.Errorf("configure case store: %w", err)
	}
	executor, err := configureRepairExecutor(
		config.Shadow.inspectionConfig(),
		store,
		config.Stabilization,
		config.PollInterval,
	)
	if err != nil {
		return applyrunner.Report{}, err
	}
	defer executor.Close()
	runner, err := applyrunner.New(applyrunner.Dependencies{
		Store:    store,
		Executor: executor,
		Locker:   caseStoreExecutionLocker{store: store},
	})
	if err != nil {
		return applyrunner.Report{}, fmt.Errorf("configure apply runner: %w", err)
	}
	return runner.Run(ctx, planned, applyselection.Policy{
		AllowedActions:         config.AllowedActions,
		AllowedDownloadClients: config.AllowedDownloadClients,
		Limit:                  automaticRepairLimit,
	})
}
