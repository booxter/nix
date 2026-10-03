package repairexecution

import (
	"fmt"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
)

type Progress int

const (
	ProgressNotApplicable Progress = iota
	ProgressNotStarted
	ProgressUnfinished
	ProgressFinished
)

func ClassifyProgress(
	store ExecutionStore,
	planned casestore.PlannedCase,
) (Progress, error) {
	progress, _, err := InspectProgress(store, planned)
	return progress, err
}

func InspectProgress(
	store ExecutionStore,
	planned casestore.PlannedCase,
) (Progress, Result, error) {
	if store == nil {
		return ProgressNotApplicable, Result{}, fmt.Errorf("execution store is required")
	}
	switch planned.Decision.Kind {
	case contracts.ActionNoRepair,
		contracts.ActionManualImportFile,
		contracts.ActionJoinParts,
		contracts.ActionRemuxBluray,
		contracts.ActionRemuxDVD:
	default:
		return ProgressNotApplicable, Result{}, fmt.Errorf(
			"planned case has unknown action %q",
			planned.Decision.Kind,
		)
	}
	caseID := planned.Assembly.Request.CaseID
	if caseID == "" || planned.Decision.CaseID() != caseID {
		return ProgressNotApplicable, Result{}, fmt.Errorf(
			"planning decision does not match its repair case",
		)
	}

	switch planned.Decision.Kind {
	case contracts.ActionNoRepair:
		return ProgressNotApplicable, Result{}, nil
	case contracts.ActionManualImportFile:
		return classifyManualImportProgress(store, caseID)
	case contracts.ActionJoinParts:
		return classifyJoinProgress(store, caseID)
	case contracts.ActionRemuxBluray, contracts.ActionRemuxDVD:
		return classifyRemuxProgress(store, caseID)
	}
	return ProgressNotApplicable, Result{}, nil
}

func classifyRemuxProgress(store ExecutionStore, caseID string) (Progress, Result, error) {
	execution, found, err := store.GetRemuxExecution(caseID)
	if err != nil {
		return ProgressNotApplicable, Result{}, fmt.Errorf("read Blu-ray remux execution: %w", err)
	}
	if !found {
		return ProgressNotStarted, Result{}, nil
	}
	result := Result{Remux: &execution}
	switch execution.State {
	case casestore.RemuxPrepared, casestore.RemuxStaged, casestore.RemuxPublished,
		casestore.RemuxImportPrepared, casestore.RemuxImportRequested:
		return ProgressUnfinished, result, nil
	case casestore.RemuxFailed, casestore.RemuxImported, casestore.RemuxImportFailed:
		return ProgressFinished, result, nil
	default:
		return ProgressNotApplicable, Result{}, fmt.Errorf("stored Blu-ray remux has unknown state %q", execution.State)
	}
}

func classifyManualImportProgress(store ExecutionStore, caseID string) (Progress, Result, error) {
	execution, found, err := store.GetManualImportExecution(caseID)
	if err != nil {
		return ProgressNotApplicable, Result{}, fmt.Errorf("read manual-import execution: %w", err)
	}
	if !found {
		return ProgressNotStarted, Result{}, nil
	}
	result := Result{ManualImport: &execution}
	switch execution.State {
	case casestore.ManualImportPrepared, casestore.ManualImportRequested:
		return ProgressUnfinished, result, nil
	case casestore.ManualImportImported, casestore.ManualImportFailed:
		return ProgressFinished, result, nil
	default:
		return ProgressNotApplicable, Result{}, fmt.Errorf(
			"stored manual import has unknown state %q",
			execution.State,
		)
	}
}

func classifyJoinProgress(store ExecutionStore, caseID string) (Progress, Result, error) {
	execution, found, err := store.GetJoinExecution(caseID)
	if err != nil {
		return ProgressNotApplicable, Result{}, fmt.Errorf("read join execution: %w", err)
	}
	if !found {
		return ProgressNotStarted, Result{}, nil
	}
	if casestore.JoinExecutionNeedsRecheck(execution) {
		return ProgressNotStarted, Result{}, nil
	}
	result := Result{Join: &execution}
	switch execution.State {
	case casestore.JoinPrepared,
		casestore.JoinArtifactReady,
		casestore.JoinDiscardPending,
		casestore.JoinPublished,
		casestore.JoinImportPrepared,
		casestore.JoinImportRequested:
		return ProgressUnfinished, result, nil
	case casestore.JoinDiscarded,
		casestore.JoinFailed,
		casestore.JoinImported,
		casestore.JoinImportFailed:
		return ProgressFinished, result, nil
	default:
		return ProgressNotApplicable, Result{}, fmt.Errorf(
			"stored join has unknown state %q",
			execution.State,
		)
	}
}
