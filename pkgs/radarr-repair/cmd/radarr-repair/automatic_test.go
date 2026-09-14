package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/applyrunner"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
	"github.com/booxter/nix-config/radarr-repair/internal/repairexecution"
	shadowrunner "github.com/booxter/nix-config/radarr-repair/internal/shadow"
)

func TestAutomaticRunRequiresPermissionAndPrintsExecution(t *testing.T) {
	t.Parallel()

	arguments, _, _, _ := validAutomaticArguments(t)
	var gotConfig automaticConfig
	app := application{automatic: func(
		_ context.Context,
		config automaticConfig,
	) (automaticReport, error) {
		gotConfig = config
		return automaticReport{
			Shadow: shadowrunner.Report{Observed: 2, Decided: 1},
			Apply: applyrunner.Report{Executions: []applyrunner.CaseResult{{
				CaseID: "case-1", Action: contracts.ActionJoinParts,
				Result: repairexecution.Result{Join: &casestore.JoinExecution{
					ExecutionID: "join-1", State: casestore.JoinImported,
				}},
			}}},
			ShadowSucceeded: true,
		}, nil
	}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := app.run(
		context.Background(), arguments, strings.NewReader(""), &stdout, &stderr,
	); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "observed=2 stored=0 submitted=0 decided=1 "+
		"already_decided=0 deferred=0 failed=0\n"+
		"apply=completed case_id=case-1 action=join_parts_v1 "+
		"state=imported execution_id=join-1\n" || stderr.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", stdout.String(), stderr.String())
	}
	if !gotConfig.AllowedActions[contracts.ActionJoinParts] ||
		!gotConfig.AllowedActions[contracts.ActionManualImportFile] ||
		len(gotConfig.AllowedActions) != 2 {
		t.Fatalf("allowed actions = %#v", gotConfig.AllowedActions)
	}
	if gotConfig.KillSwitchFile != "/run/radarr-repair/disable-apply" ||
		gotConfig.Stabilization != 20*time.Minute ||
		gotConfig.PollInterval != 3*time.Second {
		t.Fatalf("automatic config = %#v", gotConfig)
	}
}

func TestAutomaticRunRejectsUnsafeConfigurationBeforeRunning(t *testing.T) {
	t.Parallel()

	valid, _, _, _ := validAutomaticArguments(t)
	tests := []struct {
		name      string
		arguments []string
	}{
		{name: "missing apply acknowledgement", arguments: removeArgument(valid, "--apply")},
		{name: "missing allowed actions", arguments: removeArguments(valid, "--allow-action", 2)},
		{
			name: "no repair action",
			arguments: replaceArgument(
				removeArgumentPair(valid, "--allow-action"),
				"--allow-action", string(contracts.ActionNoRepair),
			),
		},
		{
			name:      "relative kill switch",
			arguments: replaceArgument(valid, "--kill-switch-file", "disable-apply"),
		},
		{
			name:      "zero stabilization",
			arguments: replaceArgument(valid, "--stabilization", "0s"),
		},
		{
			name:      "zero poll interval",
			arguments: replaceArgument(valid, "--poll-interval", "0s"),
		},
		{name: "positional argument", arguments: append(valid, "extra")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			calls := 0
			app := application{automatic: func(
				context.Context,
				automaticConfig,
			) (automaticReport, error) {
				calls++
				return automaticReport{}, nil
			}}
			if err := app.run(
				context.Background(), test.arguments, strings.NewReader(""),
				&bytes.Buffer{}, &bytes.Buffer{},
			); err == nil {
				t.Fatalf("arguments %q were accepted", test.arguments)
			}
			if calls != 0 {
				t.Fatal("automatic run started with unsafe configuration")
			}
		})
	}
}

func TestAutomaticSummaryExplainsPendingStabilization(t *testing.T) {
	t.Parallel()

	observedAt := time.Date(2026, time.September, 14, 19, 3, 52, 0, time.UTC)
	checkedAt := observedAt.Add(12 * time.Minute)
	report := automaticReport{
		ShadowSucceeded: true,
		Apply: applyrunner.Report{Executions: []applyrunner.CaseResult{{
			CaseID: "case-1",
			Action: contracts.ActionManualImportFile,
			Result: repairexecution.Result{Check: executioncheck.Result{
				Rejections: []executioncheck.Rejection{{
					Reason: executioncheck.StabilizationPending,
					Stabilization: &executioncheck.StabilizationAssessment{
						ObservedAt: observedAt, CheckedAt: checkedAt,
						RequiredAge: 15 * time.Minute, ActualAge: 12 * time.Minute,
					},
				}},
			}},
		}}},
	}
	var output bytes.Buffer
	if err := writeAutomaticSummary(&output, report); err != nil {
		t.Fatal(err)
	}
	want := "observed=0 stored=0 submitted=0 decided=0 already_decided=0 deferred=0 failed=0\n" +
		"apply=precondition_rejected case_id=case-1 action=manual_import_file_v1 " +
		"reason=stabilization_pending observed_at=2026-09-14T19:03:52Z " +
		"checked_at=2026-09-14T19:15:52Z required_age=15m0s actual_age=12m0s\n"
	if output.String() != want {
		t.Fatalf("summary = %q, want %q", output.String(), want)
	}
}

func TestAutomaticRunPlansBeforeCheckingKillSwitchOrApplying(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("planning failed")
	guard := &testApplyGuard{}
	applyCalls := 0
	report, err := runAutomaticWith(
		context.Background(),
		automaticConfig{},
		automaticDependencies{
			shadow: func(context.Context, shadowConfig) (shadowrunner.Report, error) {
				return shadowrunner.Report{Observed: 1, Failed: 1}, wantErr
			},
			guard: guard,
			apply: func(
				context.Context, automaticConfig, []casestore.PlannedCase,
			) (applyrunner.Report, error) {
				applyCalls++
				return applyrunner.Report{}, nil
			},
		},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if report.ShadowSucceeded || guard.calls != 0 || applyCalls != 0 {
		t.Fatalf("report = %#v, guard calls = %d, apply calls = %d", report, guard.calls, applyCalls)
	}
}

func TestAutomaticRunStopsWhenKillSwitchDisablesApply(t *testing.T) {
	t.Parallel()

	planned := []casestore.PlannedCase{automaticPlannedCase("case-1")}
	guard := &testApplyGuard{disabled: true}
	applyCalls := 0
	report, err := runAutomaticWith(
		context.Background(),
		automaticConfig{KillSwitchFile: "/run/disable"},
		automaticDependencies{
			shadow: func(context.Context, shadowConfig) (shadowrunner.Report, error) {
				return shadowrunner.Report{PlannedCases: planned}, nil
			},
			guard: guard,
			apply: func(
				context.Context, automaticConfig, []casestore.PlannedCase,
			) (applyrunner.Report, error) {
				applyCalls++
				return applyrunner.Report{}, nil
			},
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !report.ShadowSucceeded || !report.ApplyDisabled ||
		guard.path != "/run/disable" || applyCalls != 0 {
		t.Fatalf("report = %#v, guard = %#v, apply calls = %d", report, guard, applyCalls)
	}
}

func TestAutomaticRunFailsClosedWhenKillSwitchCannotBeInspected(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("permission denied")
	applyCalls := 0
	report, err := runAutomaticWith(
		context.Background(),
		automaticConfig{},
		automaticDependencies{
			shadow: func(context.Context, shadowConfig) (shadowrunner.Report, error) {
				return shadowrunner.Report{}, nil
			},
			guard: &testApplyGuard{err: wantErr},
			apply: func(
				context.Context, automaticConfig, []casestore.PlannedCase,
			) (applyrunner.Report, error) {
				applyCalls++
				return applyrunner.Report{}, nil
			},
		},
	)
	if !errors.Is(err, wantErr) || !report.ApplyDisabled || applyCalls != 0 {
		t.Fatalf("report = %#v, error = %v, apply calls = %d", report, err, applyCalls)
	}
}

func TestAutomaticRunAppliesOnlyPlansFromCurrentPass(t *testing.T) {
	t.Parallel()

	planned := []casestore.PlannedCase{
		automaticPlannedCase("first"), automaticPlannedCase("second"),
	}
	wantApply := applyrunner.Report{Permitted: 2, Selected: 1}
	var gotPlanned []casestore.PlannedCase
	report, err := runAutomaticWith(
		context.Background(),
		automaticConfig{},
		automaticDependencies{
			shadow: func(context.Context, shadowConfig) (shadowrunner.Report, error) {
				return shadowrunner.Report{PlannedCases: planned}, nil
			},
			guard: &testApplyGuard{},
			apply: func(
				_ context.Context,
				_ automaticConfig,
				candidates []casestore.PlannedCase,
			) (applyrunner.Report, error) {
				gotPlanned = candidates
				return wantApply, nil
			},
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(gotPlanned, planned) || !reflect.DeepEqual(report.Apply, wantApply) {
		t.Fatalf("planned = %#v, report = %#v", gotPlanned, report)
	}
}

func TestFilesystemApplyGuardTreatsAnyEntryAsDisabled(t *testing.T) {
	t.Parallel()

	guard := filesystemApplyGuard{}
	directory := t.TempDir()
	disabled, err := guard.Disabled(directory)
	if err != nil || !disabled {
		t.Fatalf("directory: disabled = %t, error = %v", disabled, err)
	}
	missing := filepath.Join(directory, "missing")
	disabled, err = guard.Disabled(missing)
	if err != nil || disabled {
		t.Fatalf("missing entry: disabled = %t, error = %v", disabled, err)
	}
	dangling := filepath.Join(directory, "dangling")
	if err := os.Symlink(filepath.Join(directory, "absent-target"), dangling); err != nil {
		t.Fatal(err)
	}
	disabled, err = guard.Disabled(dangling)
	if err != nil || !disabled {
		t.Fatalf("dangling symlink: disabled = %t, error = %v", disabled, err)
	}
}

type testApplyGuard struct {
	disabled bool
	err      error
	calls    int
	path     string
}

func (guard *testApplyGuard) Disabled(path string) (bool, error) {
	guard.calls++
	guard.path = path
	return guard.disabled, guard.err
}

func automaticPlannedCase(caseID string) casestore.PlannedCase {
	return casestore.PlannedCase{Assembly: casebuilder.Assembly{
		Request: contracts.RepairCaseV1{CaseID: caseID},
	}}
}

func validAutomaticArguments(t *testing.T) ([]string, string, string, string) {
	t.Helper()
	shadowArguments, apiKeyFile, stateDirectory, metricsFile := validShadowArguments(t)
	arguments := []string{
		"run",
		"--apply",
		"--allow-action", string(contracts.ActionJoinParts),
		"--allow-action", string(contracts.ActionManualImportFile),
		"--kill-switch-file", "/run/radarr-repair/disable-apply",
		"--stabilization", "20m",
		"--poll-interval", "3s",
	}
	arguments = append(arguments, shadowArguments[1:]...)
	return arguments, apiKeyFile, stateDirectory, metricsFile
}

func removeArgumentPair(arguments []string, name string) []string {
	result := make([]string, 0, len(arguments))
	removed := false
	for index := 0; index < len(arguments); index++ {
		if !removed && arguments[index] == name {
			index++
			removed = true
			continue
		}
		result = append(result, arguments[index])
	}
	return result
}

func removeArguments(arguments []string, name string, count int) []string {
	result := append([]string(nil), arguments...)
	for range count {
		result = removeArgumentPair(result, name)
	}
	return result
}
