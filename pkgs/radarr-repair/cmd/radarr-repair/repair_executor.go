package main

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
	"github.com/booxter/nix-config/radarr-repair/internal/joinexecution"
	"github.com/booxter/nix-config/radarr-repair/internal/joinimport"
	"github.com/booxter/nix-config/radarr-repair/internal/manualimport"
	"github.com/booxter/nix-config/radarr-repair/internal/repairexecution"
)

type configuredRepairExecutor struct {
	executor *repairexecution.Executor
	access   *controllerAccess
}

func configureRepairExecutor(
	inspection inspectConfig,
	store *casestore.Store,
	stabilization time.Duration,
	pollInterval time.Duration,
) (*configuredRepairExecutor, error) {
	access, err := configureControllerAccess(inspection)
	if err != nil {
		return nil, err
	}
	completed := false
	defer func() {
		if !completed {
			access.Close()
		}
	}()
	clock := wallClock{}
	checker, err := executioncheck.New(executioncheck.Dependencies{
		Cases:          access.inspector,
		Clock:          clock,
		JoinExecutions: access.worker,
		Stabilization:  stabilization,
	})
	if err != nil {
		return nil, fmt.Errorf("configure execution checker: %w", err)
	}
	manualImports, err := manualimport.New(manualimport.Dependencies{
		Radarr:       access.radarr,
		Store:        store,
		Clock:        clock,
		Waiter:       manualimport.Timer{},
		PollInterval: pollInterval,
	})
	if err != nil {
		return nil, fmt.Errorf("configure manual-import executor: %w", err)
	}
	joins, err := joinexecution.New(joinexecution.Dependencies{
		Worker: access.worker,
		Store:  store,
		Clock:  clock,
	})
	if err != nil {
		return nil, fmt.Errorf("configure join executor: %w", err)
	}
	joinedFileImports, err := joinimport.New(joinimport.Dependencies{
		Radarr:       access.radarr,
		Store:        store,
		Paths:        access.worker,
		Clock:        clock,
		Waiter:       manualimport.Timer{},
		PollInterval: pollInterval,
	})
	if err != nil {
		return nil, fmt.Errorf("configure joined-file import executor: %w", err)
	}
	executor, err := repairexecution.New(repairexecution.Dependencies{
		Store:             store,
		Checker:           checker,
		ManualImports:     manualImports,
		Joins:             joins,
		JoinedFileImports: joinedFileImports,
	})
	if err != nil {
		return nil, fmt.Errorf("configure repair executor: %w", err)
	}
	completed = true
	return &configuredRepairExecutor{executor: executor, access: access}, nil
}

func (configured *configuredRepairExecutor) Execute(
	ctx context.Context,
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV1,
) (repairexecution.Result, error) {
	if configured == nil || configured.executor == nil {
		return repairexecution.Result{}, fmt.Errorf("repair executor is not configured")
	}
	return configured.executor.Execute(ctx, assembly, decision)
}

func (configured *configuredRepairExecutor) Close() {
	if configured == nil {
		return
	}
	configured.access.Close()
}
