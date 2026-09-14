package repairexecution

import (
	"errors"
	"strings"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
)

func TestClassifyProgressWithoutStoredExecution(t *testing.T) {
	t.Parallel()

	for _, action := range []contracts.DecisionAction{
		contracts.ActionManualImportFile,
		contracts.ActionJoinParts,
	} {
		t.Run(string(action), func(t *testing.T) {
			t.Parallel()
			progress, err := ClassifyProgress(&progressStore{}, progressCase(action, executionCaseID))
			if err != nil || progress != ProgressNotStarted {
				t.Fatalf("progress = %v, error = %v", progress, err)
			}
		})
	}
}

func TestClassifyManualImportProgress(t *testing.T) {
	t.Parallel()

	tests := []struct {
		state casestore.ManualImportExecutionState
		want  Progress
	}{
		{casestore.ManualImportPrepared, ProgressUnfinished},
		{casestore.ManualImportRequested, ProgressUnfinished},
		{casestore.ManualImportImported, ProgressFinished},
		{casestore.ManualImportFailed, ProgressFinished},
	}
	for _, test := range tests {
		t.Run(string(test.state), func(t *testing.T) {
			t.Parallel()
			store := &progressStore{manual: &casestore.ManualImportExecution{State: test.state}}
			progress, err := ClassifyProgress(
				store,
				progressCase(contracts.ActionManualImportFile, executionCaseID),
			)
			if err != nil || progress != test.want {
				t.Fatalf("progress = %v, error = %v, want %v", progress, err, test.want)
			}
		})
	}
}

func TestClassifyJoinProgress(t *testing.T) {
	t.Parallel()

	tests := []struct {
		state casestore.JoinExecutionState
		want  Progress
	}{
		{casestore.JoinPrepared, ProgressUnfinished},
		{casestore.JoinArtifactReady, ProgressUnfinished},
		{casestore.JoinDiscardPending, ProgressUnfinished},
		{casestore.JoinPublished, ProgressUnfinished},
		{casestore.JoinScanPrepared, ProgressUnfinished},
		{casestore.JoinScanRequested, ProgressUnfinished},
		{casestore.JoinDiscarded, ProgressFinished},
		{casestore.JoinFailed, ProgressFinished},
		{casestore.JoinImported, ProgressFinished},
		{casestore.JoinImportFailed, ProgressFinished},
	}
	for _, test := range tests {
		t.Run(string(test.state), func(t *testing.T) {
			t.Parallel()
			store := &progressStore{join: &casestore.JoinExecution{State: test.state}}
			progress, err := ClassifyProgress(
				store,
				progressCase(contracts.ActionJoinParts, executionCaseID),
			)
			if err != nil || progress != test.want {
				t.Fatalf("progress = %v, error = %v, want %v", progress, err, test.want)
			}
		})
	}
}

func TestClassifyNoRepairAsNotApplicable(t *testing.T) {
	t.Parallel()

	progress, err := ClassifyProgress(
		&progressStore{},
		progressCase(contracts.ActionNoRepair, executionCaseID),
	)
	if err != nil || progress != ProgressNotApplicable {
		t.Fatalf("progress = %v, error = %v", progress, err)
	}
}

func TestClassifyProgressRejectsInvalidInput(t *testing.T) {
	t.Parallel()

	mismatched := progressCase(contracts.ActionJoinParts, anotherExecutionCaseID)
	mismatched.Assembly.Request.CaseID = executionCaseID
	tests := []struct {
		name    string
		store   ExecutionStore
		planned casestore.PlannedCase
		want    string
	}{
		{
			name:    "missing store",
			planned: progressCase(contracts.ActionJoinParts, executionCaseID),
			want:    "store is required",
		},
		{
			name:    "different decision case",
			store:   &progressStore{},
			planned: mismatched,
			want:    "does not match",
		},
		{
			name:    "unknown action",
			store:   &progressStore{},
			planned: progressCase("erase", executionCaseID),
			want:    "unknown action",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			_, err := ClassifyProgress(test.store, test.planned)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func TestClassifyProgressReportsStoredReadFailure(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("broken record")
	_, err := ClassifyProgress(
		&progressStore{err: wantErr},
		progressCase(contracts.ActionManualImportFile, executionCaseID),
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
}

type progressStore struct {
	manual *casestore.ManualImportExecution
	join   *casestore.JoinExecution
	err    error
}

func (store *progressStore) GetManualImportExecution(
	string,
) (casestore.ManualImportExecution, bool, error) {
	if store.err != nil || store.manual == nil {
		return casestore.ManualImportExecution{}, false, store.err
	}
	return *store.manual, true, nil
}

func (store *progressStore) GetJoinExecution(
	string,
) (casestore.JoinExecution, bool, error) {
	if store.err != nil || store.join == nil {
		return casestore.JoinExecution{}, false, store.err
	}
	return *store.join, true, nil
}

func progressCase(
	action contracts.DecisionAction,
	decisionCaseID string,
) casestore.PlannedCase {
	planned := casestore.PlannedCase{
		Assembly: casebuilder.Assembly{
			Request: contracts.RepairCaseV1{CaseID: decisionCaseID},
		},
		Decision: contracts.RepairDecisionV1{Kind: action},
	}
	switch action {
	case contracts.ActionNoRepair:
		planned.Decision.NoRepair = &contracts.NoRepairDecision{CaseID: decisionCaseID}
	case contracts.ActionManualImportFile:
		planned.Decision.ManualImportFile = &contracts.ManualImportFileDecision{
			CaseID: decisionCaseID,
		}
	case contracts.ActionJoinParts:
		planned.Decision.JoinParts = &contracts.JoinDecision{CaseID: decisionCaseID}
	}
	return planned
}

const (
	executionCaseID        = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	anotherExecutionCaseID = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)
