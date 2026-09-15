package repairexecution

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
)

type Checker interface {
	Check(
		context.Context,
		casebuilder.Assembly,
		contracts.RepairDecisionV2,
	) (executioncheck.Result, error)
}

type ManualImporter interface {
	Execute(
		context.Context,
		decisionpolicy.AuthorizedManualImport,
	) (casestore.ManualImportExecution, error)
}

type JoinExecutor interface {
	Execute(
		context.Context,
		decisionpolicy.AuthorizedJoin,
		map[controller.FileID]string,
	) (casestore.JoinExecution, error)
}

type JoinedFileImporter interface {
	Execute(context.Context, string) (casestore.JoinExecution, error)
}

type ExecutionStore interface {
	GetManualImportExecution(string) (casestore.ManualImportExecution, bool, error)
	GetJoinExecution(string) (casestore.JoinExecution, bool, error)
}

type Dependencies struct {
	Store             ExecutionStore
	Checker           Checker
	ManualImports     ManualImporter
	Joins             JoinExecutor
	JoinedFileImports JoinedFileImporter
}

type Executor struct {
	dependencies Dependencies
}

type Result struct {
	Check        executioncheck.Result
	ManualImport *casestore.ManualImportExecution
	Join         *casestore.JoinExecution
	Resumed      bool
}

var _ ExecutionStore = (*casestore.Store)(nil)

func New(dependencies Dependencies) (*Executor, error) {
	switch {
	case dependencies.Store == nil:
		return nil, fmt.Errorf("execution store is required")
	case dependencies.Checker == nil:
		return nil, fmt.Errorf("execution checker is required")
	case dependencies.ManualImports == nil:
		return nil, fmt.Errorf("manual-import executor is required")
	case dependencies.Joins == nil:
		return nil, fmt.Errorf("join executor is required")
	case dependencies.JoinedFileImports == nil:
		return nil, fmt.Errorf("joined-file import executor is required")
	default:
		return &Executor{dependencies: dependencies}, nil
	}
}

func (executor *Executor) Execute(
	ctx context.Context,
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV2,
) (Result, error) {
	if executor == nil {
		return Result{}, fmt.Errorf("repair executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	if result, found, err := executor.resumeExisting(ctx, assembly, decision); found || err != nil {
		return result, err
	}

	checked, err := executor.dependencies.Checker.Check(ctx, assembly, decision)
	result := Result{Check: checked}
	if err != nil {
		return result, fmt.Errorf("check repair execution: %w", err)
	}
	if !checked.Accepted() {
		return result, nil
	}
	if checked.Authorization.ManualImport != nil {
		return executor.executeManualImport(ctx, result, *checked.Authorization.ManualImport)
	}
	return executor.executeJoin(ctx, result, assembly, *checked.Authorization.Join)
}

func (executor *Executor) resumeExisting(
	ctx context.Context,
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV2,
) (Result, bool, error) {
	caseID := assembly.Request.CaseID
	switch decision.Kind {
	case contracts.ActionManualImportFile:
		execution, found, err := executor.dependencies.Store.GetManualImportExecution(caseID)
		result := Result{ManualImport: &execution, Resumed: found}
		if err != nil {
			return Result{}, false, fmt.Errorf("read manual-import execution: %w", err)
		}
		if !found {
			return Result{}, false, nil
		}
		validation := decisionpolicy.ValidateManualImport(assembly, decision)
		if !validation.Accepted() {
			return result, true, fmt.Errorf("stored manual import is no longer authorized")
		}
		resumed, err := executor.executeManualImport(ctx, result, *validation.Authorized)
		return resumed, true, err
	case contracts.ActionJoinParts:
		execution, found, err := executor.dependencies.Store.GetJoinExecution(caseID)
		result := Result{Join: &execution, Resumed: found}
		if err != nil {
			return Result{}, false, fmt.Errorf("read join execution: %w", err)
		}
		if !found {
			return Result{}, false, nil
		}
		validation := decisionpolicy.ValidateJoin(assembly, decision)
		if !validation.Accepted() {
			return result, true, fmt.Errorf("stored join is no longer authorized")
		}
		executionID, err := casestore.JoinExecutionID(*validation.Authorized)
		if err != nil {
			return result, true, fmt.Errorf("identify authorized join: %w", err)
		}
		if execution.ExecutionID != executionID {
			return result, true, fmt.Errorf("stored join does not match the authorized join")
		}
		resumed, err := executor.resumeJoin(ctx, result, assembly, *validation.Authorized)
		return resumed, true, err
	default:
		return Result{}, false, nil
	}
}

func (executor *Executor) executeManualImport(
	ctx context.Context,
	result Result,
	authorized decisionpolicy.AuthorizedManualImport,
) (Result, error) {
	execution, err := executor.dependencies.ManualImports.Execute(ctx, authorized)
	result.ManualImport = &execution
	if err != nil {
		return result, fmt.Errorf("execute manual import: %w", err)
	}
	switch execution.State {
	case casestore.ManualImportImported, casestore.ManualImportFailed:
		return result, nil
	default:
		return result, fmt.Errorf(
			"manual import returned non-terminal state %q",
			execution.State,
		)
	}
}

func (executor *Executor) executeJoin(
	ctx context.Context,
	result Result,
	assembly casebuilder.Assembly,
	authorized decisionpolicy.AuthorizedJoin,
) (Result, error) {
	paths, err := selectedPaths(assembly, authorized)
	if err != nil {
		return result, err
	}
	execution, err := executor.dependencies.Joins.Execute(ctx, authorized, paths)
	result.Join = &execution
	if err != nil {
		return result, fmt.Errorf("execute media join: %w", err)
	}
	switch execution.State {
	case casestore.JoinDiscarded, casestore.JoinFailed:
		return result, nil
	case casestore.JoinPublished:
	default:
		return result, fmt.Errorf("join returned non-terminal state %q", execution.State)
	}
	return executor.executeJoinedFileImport(ctx, result, authorized.CaseID)
}

func (executor *Executor) resumeJoin(
	ctx context.Context,
	result Result,
	assembly casebuilder.Assembly,
	authorized decisionpolicy.AuthorizedJoin,
) (Result, error) {
	switch result.Join.State {
	case casestore.JoinPrepared,
		casestore.JoinArtifactReady,
		casestore.JoinDiscardPending:
		return executor.executeJoin(ctx, result, assembly, authorized)
	case casestore.JoinPublished,
		casestore.JoinImportPrepared,
		casestore.JoinImportRequested:
		return executor.executeJoinedFileImport(ctx, result, authorized.CaseID)
	case casestore.JoinDiscarded,
		casestore.JoinFailed,
		casestore.JoinImported,
		casestore.JoinImportFailed:
		return result, nil
	default:
		return result, fmt.Errorf("cannot resume join from state %q", result.Join.State)
	}
}

func (executor *Executor) executeJoinedFileImport(
	ctx context.Context,
	result Result,
	caseID string,
) (Result, error) {
	execution, err := executor.dependencies.JoinedFileImports.Execute(ctx, caseID)
	result.Join = &execution
	if err != nil {
		return result, fmt.Errorf("import joined file: %w", err)
	}
	switch execution.State {
	case casestore.JoinImported, casestore.JoinImportFailed:
		return result, nil
	default:
		return result, fmt.Errorf(
			"joined-file import returned non-terminal state %q",
			execution.State,
		)
	}
}

func selectedPaths(
	assembly casebuilder.Assembly,
	authorized decisionpolicy.AuthorizedJoin,
) (map[controller.FileID]string, error) {
	available := make(map[controller.FileID]string)
	for _, mapping := range assembly.LocalSnapshot.Observation.Inventory.Paths {
		available[mapping.FileID] = mapping.AbsolutePath
	}
	selected := make(map[controller.FileID]string, len(authorized.OrderedParts))
	for _, part := range authorized.OrderedParts {
		path, found := available[part.FileID]
		if !found {
			return nil, fmt.Errorf("authorized join file %q has no stored path", part.FileID)
		}
		selected[part.FileID] = path
	}
	return selected, nil
}
