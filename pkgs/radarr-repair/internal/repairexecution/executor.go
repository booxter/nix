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
		contracts.RepairDecisionV1,
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

type Dependencies struct {
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
}

func New(dependencies Dependencies) (*Executor, error) {
	switch {
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
	decision contracts.RepairDecisionV1,
) (Result, error) {
	if executor == nil {
		return Result{}, fmt.Errorf("repair executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
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

	execution, err = executor.dependencies.JoinedFileImports.Execute(ctx, authorized.CaseID)
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
