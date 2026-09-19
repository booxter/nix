package repairexecution

import (
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
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
	if store == nil {
		return ProgressNotApplicable, fmt.Errorf("execution store is required")
	}
	switch planned.Decision.Kind {
	case contracts.ActionNoRepair,
		contracts.ActionManualImportFile,
		contracts.ActionJoinParts,
		contracts.ActionRemuxBluray:
	default:
		return ProgressNotApplicable, fmt.Errorf(
			"planned case has unknown action %q",
			planned.Decision.Kind,
		)
	}
	caseID := planned.Assembly.Request.CaseID
	if caseID == "" || planned.Decision.CaseID() != caseID {
		return ProgressNotApplicable, fmt.Errorf(
			"planning decision does not match its repair case",
		)
	}

	switch planned.Decision.Kind {
	case contracts.ActionNoRepair:
		return ProgressNotApplicable, nil
	case contracts.ActionManualImportFile:
		return classifyManualImportProgress(store, caseID)
	case contracts.ActionJoinParts:
		return classifyJoinProgress(store, caseID)
	case contracts.ActionRemuxBluray:
		return classifyRemuxProgress(store, caseID)
	}
	return ProgressNotApplicable, nil
}

func classifyRemuxProgress(store ExecutionStore, caseID string) (Progress, error) {
	execution, found, err := store.GetRemuxExecution(caseID)
	if err != nil {
		return ProgressNotApplicable, fmt.Errorf("read Blu-ray remux execution: %w", err)
	}
	if !found {
		return ProgressNotStarted, nil
	}
	switch execution.State {
	case casestore.RemuxPrepared, casestore.RemuxStaged, casestore.RemuxPublished,
		casestore.RemuxImportPrepared, casestore.RemuxImportRequested:
		return ProgressUnfinished, nil
	case casestore.RemuxFailed, casestore.RemuxImported, casestore.RemuxImportFailed:
		return ProgressFinished, nil
	default:
		return ProgressNotApplicable, fmt.Errorf("stored Blu-ray remux has unknown state %q", execution.State)
	}
}

func classifyManualImportProgress(store ExecutionStore, caseID string) (Progress, error) {
	execution, found, err := store.GetManualImportExecution(caseID)
	if err != nil {
		return ProgressNotApplicable, fmt.Errorf("read manual-import execution: %w", err)
	}
	if !found {
		return ProgressNotStarted, nil
	}
	switch execution.State {
	case casestore.ManualImportPrepared, casestore.ManualImportRequested:
		return ProgressUnfinished, nil
	case casestore.ManualImportImported, casestore.ManualImportFailed:
		return ProgressFinished, nil
	default:
		return ProgressNotApplicable, fmt.Errorf(
			"stored manual import has unknown state %q",
			execution.State,
		)
	}
}

func classifyJoinProgress(store ExecutionStore, caseID string) (Progress, error) {
	execution, found, err := store.GetJoinExecution(caseID)
	if err != nil {
		return ProgressNotApplicable, fmt.Errorf("read join execution: %w", err)
	}
	if !found {
		return ProgressNotStarted, nil
	}
	switch execution.State {
	case casestore.JoinPrepared,
		casestore.JoinArtifactReady,
		casestore.JoinDiscardPending,
		casestore.JoinPublished,
		casestore.JoinImportPrepared,
		casestore.JoinImportRequested:
		return ProgressUnfinished, nil
	case casestore.JoinDiscarded,
		casestore.JoinFailed,
		casestore.JoinImported,
		casestore.JoinImportFailed:
		return ProgressFinished, nil
	default:
		return ProgressNotApplicable, fmt.Errorf(
			"stored join has unknown state %q",
			execution.State,
		)
	}
}
