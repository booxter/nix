package joinexecution

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/workerclient"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

type Worker interface {
	StageJoin(
		context.Context,
		string,
		decisionpolicy.AuthorizedJoin,
		map[controller.FileID]string,
	) (workerclient.StageJoinExchange, error)
	PublishJoin(context.Context, workerclient.Artifact) (workercontracts.PublishResponseV1, error)
	DiscardJoin(context.Context, workerclient.Artifact) (workercontracts.DiscardResponseV1, error)
}

type Store interface {
	PrepareJoin(
		decisionpolicy.AuthorizedJoin,
		time.Time,
	) (casestore.JoinExecution, bool, error)
	RecordJoinStage(
		decisionpolicy.AuthorizedJoin,
		workercontracts.StageJoinRequestV1,
		workercontracts.StageJoinResponseV1,
		time.Time,
	) (casestore.JoinExecution, bool, error)
	RecordJoinPublish(
		string,
		workercontracts.PublishResponseV1,
		time.Time,
	) (casestore.JoinExecution, bool, error)
	RecordJoinDiscard(
		string,
		workercontracts.DiscardResponseV1,
		time.Time,
	) (casestore.JoinExecution, bool, error)
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
		return nil, fmt.Errorf("join worker is required")
	case dependencies.Store == nil:
		return nil, fmt.Errorf("join execution store is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("join execution clock is required")
	default:
		return &Executor{dependencies: dependencies}, nil
	}
}

func (executor *Executor) Execute(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedJoin,
	absolutePaths map[controller.FileID]string,
) (casestore.JoinExecution, error) {
	if executor == nil {
		return casestore.JoinExecution{}, fmt.Errorf("join executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casestore.JoinExecution{}, err
	}
	preparedAt, err := executor.now()
	if err != nil {
		return casestore.JoinExecution{}, err
	}
	execution, _, err := executor.dependencies.Store.PrepareJoin(authorized, preparedAt)
	if err != nil {
		return casestore.JoinExecution{}, fmt.Errorf("prepare join: %w", err)
	}

	for {
		switch execution.State {
		case casestore.JoinPrepared:
			execution, err = executor.stage(ctx, authorized, absolutePaths, execution)
		case casestore.JoinArtifactReady:
			execution, err = executor.publish(ctx, execution)
		case casestore.JoinDiscardPending:
			execution, err = executor.discard(ctx, execution)
		case casestore.JoinPublished, casestore.JoinDiscarded, casestore.JoinFailed:
			return execution, nil
		default:
			return execution, fmt.Errorf("unknown join execution state %q", execution.State)
		}
		if err != nil {
			return execution, err
		}
	}
}

func (executor *Executor) stage(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedJoin,
	absolutePaths map[controller.FileID]string,
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	exchange, err := executor.dependencies.Worker.StageJoin(
		ctx,
		execution.ExecutionID,
		authorized,
		absolutePaths,
	)
	if err != nil {
		return execution, fmt.Errorf("stage join: %w", err)
	}
	updatedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	updated, _, err := executor.dependencies.Store.RecordJoinStage(
		authorized,
		exchange.Request,
		exchange.Response,
		updatedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("record staged join: %w", err)
	}
	return updated, nil
}

func (executor *Executor) publish(
	ctx context.Context,
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	artifact, err := executionArtifact(execution)
	if err != nil {
		return execution, err
	}
	response, err := executor.dependencies.Worker.PublishJoin(ctx, artifact)
	if err != nil {
		return execution, fmt.Errorf("publish join: %w", err)
	}
	updatedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	updated, _, err := executor.dependencies.Store.RecordJoinPublish(
		execution.Authorization.CaseID,
		response,
		updatedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("record published join: %w", err)
	}
	return updated, nil
}

func (executor *Executor) discard(
	ctx context.Context,
	execution casestore.JoinExecution,
) (casestore.JoinExecution, error) {
	artifact, err := executionArtifact(execution)
	if err != nil {
		return execution, err
	}
	response, err := executor.dependencies.Worker.DiscardJoin(ctx, artifact)
	if err != nil {
		return execution, fmt.Errorf("discard join: %w", err)
	}
	updatedAt, err := executor.now()
	if err != nil {
		return execution, err
	}
	updated, _, err := executor.dependencies.Store.RecordJoinDiscard(
		execution.Authorization.CaseID,
		response,
		updatedAt,
	)
	if err != nil {
		return execution, fmt.Errorf("record discarded join: %w", err)
	}
	return updated, nil
}

func (executor *Executor) now() (time.Time, error) {
	now := executor.dependencies.Clock.Now().UTC()
	if now.IsZero() {
		return time.Time{}, fmt.Errorf("join execution clock returned a zero time")
	}
	return now, nil
}

func executionArtifact(execution casestore.JoinExecution) (workerclient.Artifact, error) {
	if execution.Artifact == nil {
		return workerclient.Artifact{}, fmt.Errorf(
			"join execution state %q has no staged artifact",
			execution.State,
		)
	}
	return workerclient.Artifact{
		ID: execution.Artifact.ID, Fingerprint: execution.Artifact.Fingerprint,
	}, nil
}
