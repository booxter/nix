package applyrunner

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/applyselection"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/repairexecution"
)

type Executor interface {
	Execute(
		context.Context,
		casebuilder.Assembly,
		contracts.RepairDecisionV1,
	) (repairexecution.Result, error)
}

type Lease interface {
	Release()
}

type Locker interface {
	Acquire() (Lease, error)
}

type Dependencies struct {
	Store    repairexecution.ExecutionStore
	Executor Executor
	Locker   Locker
}

type Runner struct {
	dependencies Dependencies
}

type CaseResult struct {
	CaseID string
	Action contracts.DecisionAction
	Result repairexecution.Result
}

type Report struct {
	Permitted  int
	Finished   int
	Selected   int
	Executions []CaseResult
}

func New(dependencies Dependencies) (*Runner, error) {
	switch {
	case dependencies.Store == nil:
		return nil, fmt.Errorf("execution store is required")
	case dependencies.Executor == nil:
		return nil, fmt.Errorf("repair executor is required")
	case dependencies.Locker == nil:
		return nil, fmt.Errorf("execution locker is required")
	default:
		return &Runner{dependencies: dependencies}, nil
	}
}

func (runner *Runner) Run(
	ctx context.Context,
	planned []casestore.PlannedCase,
	policy applyselection.Policy,
) (Report, error) {
	if runner == nil {
		return Report{}, fmt.Errorf("apply runner is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Report{}, err
	}

	report := Report{}
	unfinished := make([]casestore.PlannedCase, 0, len(planned))
	for _, candidate := range planned {
		permitted, err := applyselection.Permitted(candidate.Decision.Kind, policy)
		if err != nil {
			return report, fmt.Errorf("check repair permission: %w", err)
		}
		if !permitted {
			continue
		}
		report.Permitted++
		progress, err := repairexecution.ClassifyProgress(runner.dependencies.Store, candidate)
		if err != nil {
			return report, fmt.Errorf(
				"classify repair case %q: %w",
				candidate.Assembly.Request.CaseID,
				err,
			)
		}
		switch progress {
		case repairexecution.ProgressNotStarted, repairexecution.ProgressUnfinished:
			unfinished = append(unfinished, candidate)
		case repairexecution.ProgressFinished:
			report.Finished++
		default:
			return report, fmt.Errorf(
				"permitted repair case %q is not executable",
				candidate.Assembly.Request.CaseID,
			)
		}
	}

	selected, err := applyselection.Select(unfinished, policy)
	if err != nil {
		return report, fmt.Errorf("select repairs: %w", err)
	}
	report.Selected = len(selected)
	if len(selected) == 0 {
		return report, nil
	}
	lease, err := runner.dependencies.Locker.Acquire()
	if err != nil {
		return report, fmt.Errorf("acquire repair execution lock: %w", err)
	}
	if lease == nil {
		return report, fmt.Errorf("execution locker returned no lease")
	}
	defer lease.Release()

	for _, candidate := range selected {
		result, executeErr := runner.dependencies.Executor.Execute(
			ctx,
			candidate.Assembly,
			candidate.Decision,
		)
		report.Executions = append(report.Executions, CaseResult{
			CaseID: candidate.Assembly.Request.CaseID,
			Action: candidate.Decision.Kind,
			Result: result,
		})
		if executeErr != nil {
			return report, fmt.Errorf(
				"execute repair case %q: %w",
				candidate.Assembly.Request.CaseID,
				executeErr,
			)
		}
	}
	return report, nil
}
