package remuxexecution

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/workerclient"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

type Worker interface {
	StageBlurayRemux(context.Context, string, decisionpolicy.AuthorizedRemux,
		map[controller.FileID]string) (workerclient.BlurayRemuxExchange, error)
	PublishBlurayRemux(context.Context, workercontracts.BlurayRemuxRequestV1,
		workerclient.Artifact) (workercontracts.BlurayPublishResponseV1, error)
}

type Store interface {
	PrepareRemux(decisionpolicy.AuthorizedRemux, time.Time) (casestore.RemuxExecution, bool, error)
	RecordRemuxStage(string, workerclient.BlurayRemuxExchange, time.Time) (casestore.RemuxExecution, bool, error)
	RecordRemuxPublish(string, workercontracts.BlurayPublishResponseV1, time.Time) (casestore.RemuxExecution, bool, error)
}

type Dependencies struct {
	Worker Worker
	Store  Store
	Clock  controller.Clock
}

type Executor struct {
	dependencies Dependencies
}

func New(dependencies Dependencies) (*Executor, error) {
	switch {
	case dependencies.Worker == nil:
		return nil, fmt.Errorf("Blu-ray remux worker is required")
	case dependencies.Store == nil:
		return nil, fmt.Errorf("Blu-ray remux store is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("Blu-ray remux clock is required")
	default:
		return &Executor{dependencies: dependencies}, nil
	}
}

func (executor *Executor) Execute(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedRemux,
	absolutePaths map[controller.FileID]string,
) (casestore.RemuxExecution, error) {
	if executor == nil {
		return casestore.RemuxExecution{}, fmt.Errorf("Blu-ray remux executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casestore.RemuxExecution{}, err
	}
	preparedAt, err := executor.now()
	if err != nil {
		return casestore.RemuxExecution{}, err
	}
	execution, _, err := executor.dependencies.Store.PrepareRemux(authorized, preparedAt)
	if err != nil {
		return casestore.RemuxExecution{}, fmt.Errorf("prepare Blu-ray remux: %w", err)
	}
	for {
		switch execution.State {
		case casestore.RemuxPrepared:
			execution, err = executor.stage(ctx, authorized, absolutePaths, execution)
		case casestore.RemuxStaged:
			execution, err = executor.publish(ctx, execution)
		case casestore.RemuxPublished, casestore.RemuxFailed:
			return execution, nil
		default:
			return execution, fmt.Errorf("unknown Blu-ray remux state %q", execution.State)
		}
		if err != nil {
			return execution, err
		}
	}
}

func (executor *Executor) stage(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedRemux,
	absolutePaths map[controller.FileID]string,
	execution casestore.RemuxExecution,
) (casestore.RemuxExecution, error) {
	exchange, err := executor.dependencies.Worker.StageBlurayRemux(
		ctx, execution.ExecutionID, authorized, absolutePaths,
	)
	if err != nil {
		return execution, fmt.Errorf("stage Blu-ray remux: %w", err)
	}
	updatedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	updated, _, err := executor.dependencies.Store.RecordRemuxStage(
		authorized.CaseID, exchange, updatedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("record staged Blu-ray remux: %w", err)
	}
	return updated, nil
}

func (executor *Executor) publish(
	ctx context.Context,
	execution casestore.RemuxExecution,
) (casestore.RemuxExecution, error) {
	if execution.StageRequest == nil || execution.Artifact == nil {
		return execution, fmt.Errorf("staged Blu-ray remux has no artifact")
	}
	response, err := executor.dependencies.Worker.PublishBlurayRemux(
		ctx, *execution.StageRequest,
		workerclient.Artifact{ID: execution.Artifact.ID, Fingerprint: execution.Artifact.Fingerprint},
	)
	if err != nil {
		return execution, fmt.Errorf("publish Blu-ray remux: %w", err)
	}
	updatedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	updated, _, err := executor.dependencies.Store.RecordRemuxPublish(
		execution.Authorization.CaseID, response, updatedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("record published Blu-ray remux: %w", err)
	}
	return updated, nil
}

func (executor *Executor) now() (time.Time, error) {
	now := executor.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("Blu-ray remux clock returned a zero time")
	}
	return now, nil
}
