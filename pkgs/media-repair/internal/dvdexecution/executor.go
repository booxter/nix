package dvdexecution

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
	StageDVDRemux(context.Context, string, decisionpolicy.AuthorizedDVD,
		map[controller.FileID]string) (workerclient.DVDRemuxExchange, error)
	PublishDVDRemux(context.Context, workercontracts.DVDRemuxRequestV1,
		workerclient.Artifact) (workercontracts.DVDPublishResponseV1, error)
}

type Store interface {
	PrepareDVD(decisionpolicy.AuthorizedDVD, time.Time) (casestore.RemuxExecution, bool, error)
	RecordDVDStage(string, workerclient.DVDRemuxExchange, time.Time) (casestore.RemuxExecution, bool, error)
	RecordDVDPublish(string, workercontracts.DVDPublishResponseV1, time.Time) (casestore.RemuxExecution, bool, error)
}

type Dependencies struct {
	Worker Worker
	Store  Store
	Clock  controller.Clock
}

type Executor struct{ dependencies Dependencies }

func New(dependencies Dependencies) (*Executor, error) {
	if dependencies.Worker == nil || dependencies.Store == nil || dependencies.Clock == nil {
		return nil, fmt.Errorf("DVD executor needs worker, store, and clock")
	}
	return &Executor{dependencies: dependencies}, nil
}

func (executor *Executor) Execute(
	ctx context.Context, authorized decisionpolicy.AuthorizedDVD,
	absolutePaths map[controller.FileID]string,
) (casestore.RemuxExecution, error) {
	if executor == nil {
		return casestore.RemuxExecution{}, fmt.Errorf("DVD executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return casestore.RemuxExecution{}, err
	}
	at, err := executor.now()
	if err != nil {
		return casestore.RemuxExecution{}, err
	}
	execution, _, err := executor.dependencies.Store.PrepareDVD(authorized, at)
	if err != nil {
		return casestore.RemuxExecution{}, fmt.Errorf("prepare DVD remux: %w", err)
	}
	for {
		switch execution.State {
		case casestore.RemuxPrepared:
			exchange, stageErr := executor.dependencies.Worker.StageDVDRemux(
				ctx, execution.ExecutionID, authorized, absolutePaths,
			)
			if stageErr != nil {
				return execution, fmt.Errorf("stage DVD remux: %w", stageErr)
			}
			at, err = executor.now()
			if err == nil {
				execution, _, err = executor.dependencies.Store.RecordDVDStage(authorized.CaseID, exchange, at)
			}
		case casestore.RemuxStaged:
			if execution.DVDStageRequest == nil || execution.Artifact == nil {
				return execution, fmt.Errorf("staged DVD remux has no artifact")
			}
			response, publishErr := executor.dependencies.Worker.PublishDVDRemux(
				ctx, *execution.DVDStageRequest,
				workerclient.Artifact{ID: execution.Artifact.ID, Fingerprint: execution.Artifact.Fingerprint},
			)
			if publishErr != nil {
				return execution, fmt.Errorf("publish DVD remux: %w", publishErr)
			}
			at, err = executor.now()
			if err == nil {
				execution, _, err = executor.dependencies.Store.RecordDVDPublish(authorized.CaseID, response, at)
			}
		case casestore.RemuxPublished, casestore.RemuxFailed:
			return execution, nil
		default:
			return execution, fmt.Errorf("unexpected DVD remux state %q", execution.State)
		}
		if err != nil {
			return execution, err
		}
	}
}

func (executor *Executor) now() (time.Time, error) {
	at := executor.dependencies.Clock.Now().UTC()
	if at.IsZero() {
		return time.Time{}, fmt.Errorf("DVD clock returned a zero time")
	}
	return at, nil
}
