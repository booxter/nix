package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/applyrunner"
	"github.com/booxter/nix-config/radarr-repair/internal/applyselection"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	shadowrunner "github.com/booxter/nix-config/radarr-repair/internal/shadow"
)

const automaticRepairLimit = 1

type automaticConfig struct {
	Shadow         shadowConfig
	AllowedActions map[contracts.DecisionAction]bool
	KillSwitchFile string
	Stabilization  time.Duration
	PollInterval   time.Duration
}

type automaticReport struct {
	Shadow          shadowrunner.Report
	Apply           applyrunner.Report
	ShadowSucceeded bool
	ApplyDisabled   bool
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

type automaticDependencies struct {
	shadow shadowFunc
	guard  applyGuard
	apply  automaticApplyFunc
}

type allowedActionsValue struct {
	actions map[contracts.DecisionAction]bool
}

func (value *allowedActionsValue) String() string {
	return ""
}

func (value *allowedActionsValue) Set(raw string) error {
	action := contracts.DecisionAction(raw)
	switch action {
	case contracts.ActionJoinParts, contracts.ActionManualImportFile:
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
				"--kill-switch-file FILE --radarr-url URL --radarr-api-key-file FILE "+
				"--transmission-url URL --worker-socket PATH --worker-root ID=PATH "+
				"--planner-socket PATH --state-directory DIR --metrics-file FILE",
		)
	}
	shadowValues := addShadowFlags(flags)
	apply := flags.Bool("apply", false, "acknowledge that one permitted repair may be applied")
	allowed := allowedActionsValue{actions: make(map[contracts.DecisionAction]bool)}
	flags.Var(&allowed, "allow-action", "repair action to permit; repeatable")
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
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("run accepts no positional arguments")
	}
	config := automaticConfig{
		Shadow:         shadowValues.Config(),
		AllowedActions: allowed.actions,
		KillSwitchFile: *killSwitchFile,
		Stabilization:  *stabilization,
		PollInterval:   *pollInterval,
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
	execution := report.Apply.Executions[0]
	_, err := fmt.Fprintf(
		writer,
		"apply=executed case_id=%s action=%s\n",
		execution.CaseID,
		execution.Action,
	)
	return err
}

func runAutomaticOnce(ctx context.Context, config automaticConfig) (automaticReport, error) {
	return runAutomaticWith(ctx, config, automaticDependencies{
		shadow: runShadowOnce,
		guard:  filesystemApplyGuard{},
		apply:  applyCurrentCases,
	})
}

func runAutomaticWith(
	ctx context.Context,
	config automaticConfig,
	dependencies automaticDependencies,
) (automaticReport, error) {
	report := automaticReport{}
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
	return report, err
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
		AllowedActions: config.AllowedActions,
		Limit:          automaticRepairLimit,
	})
}
