package remuximport

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/publishedimport"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

type Store interface {
	Get(string) (casestore.CaseRecord, bool, error)
	GetRemuxExecution(string) (casestore.RemuxExecution, bool, error)
	PrepareRemuxImport(string, casestore.JoinImportRequest, time.Time) (casestore.RemuxExecution, bool, error)
	MarkRemuxImportRequested(string, int64, time.Time) (casestore.RemuxExecution, bool, error)
	MarkRemuxImported(string, controller.RadarrImportedFile, time.Time) (casestore.RemuxExecution, bool, error)
	MarkRemuxImportFailed(string, time.Time) (casestore.RemuxExecution, bool, error)
}

type Dependencies struct {
	Radarr       publishedimport.Radarr
	Store        Store
	Paths        publishedimport.PublishedPathResolver
	Clock        controller.Clock
	Waiter       servarr.Waiter
	PollInterval time.Duration
}

type Executor struct {
	store Store
	core  *publishedimport.Executor
}

func New(dependencies Dependencies) (*Executor, error) {
	if dependencies.Store == nil {
		return nil, fmt.Errorf("Blu-ray remux import store is required")
	}
	core, err := publishedimport.New(publishedimport.Dependencies{
		Radarr:       dependencies.Radarr,
		Store:        &storeAdapter{Store: dependencies.Store},
		Paths:        dependencies.Paths,
		Clock:        dependencies.Clock,
		Waiter:       dependencies.Waiter,
		PollInterval: dependencies.PollInterval,
	})
	if err != nil {
		return nil, err
	}
	return &Executor{store: dependencies.Store, core: core}, nil
}

func (executor *Executor) Execute(ctx context.Context, caseID string) (casestore.RemuxExecution, error) {
	if executor == nil {
		return casestore.RemuxExecution{}, fmt.Errorf("Blu-ray remux importer is not configured")
	}
	_, runErr := executor.core.Execute(ctx, caseID)
	execution, found, err := executor.store.GetRemuxExecution(caseID)
	if err != nil {
		return casestore.RemuxExecution{}, errors.Join(runErr, err)
	}
	if !found {
		return casestore.RemuxExecution{}, errors.Join(runErr, fmt.Errorf("Blu-ray remux is absent"))
	}
	return execution, runErr
}

type storeAdapter struct {
	Store
}

func (adapter *storeAdapter) GetExecution(caseID string) (publishedimport.Execution, bool, error) {
	execution, found, err := adapter.GetRemuxExecution(caseID)
	if err != nil || !found {
		return publishedimport.Execution{}, found, err
	}
	mapped, err := asPublishedExecution(execution)
	return mapped, true, err
}

func (adapter *storeAdapter) PrepareImport(
	caseID string, request casestore.JoinImportRequest, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.PrepareRemuxImport(caseID, request, at)
	return mapResult(execution, changed, err)
}

func (adapter *storeAdapter) MarkImportRequested(
	caseID string, commandID int64, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.MarkRemuxImportRequested(caseID, commandID, at)
	return mapResult(execution, changed, err)
}

func (adapter *storeAdapter) MarkImported(
	caseID string, imported controller.RadarrImportedFile, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.MarkRemuxImported(caseID, imported, at)
	return mapResult(execution, changed, err)
}

func (adapter *storeAdapter) MarkImportFailed(
	caseID string, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.MarkRemuxImportFailed(caseID, at)
	return mapResult(execution, changed, err)
}

func mapResult(
	execution casestore.RemuxExecution, changed bool, err error,
) (publishedimport.Execution, bool, error) {
	if err != nil {
		return publishedimport.Execution{}, changed, err
	}
	mapped, err := asPublishedExecution(execution)
	return mapped, changed, err
}

func asPublishedExecution(execution casestore.RemuxExecution) (publishedimport.Execution, error) {
	var state publishedimport.State
	switch execution.State {
	case casestore.RemuxPublished:
		state = publishedimport.Published
	case casestore.RemuxImportPrepared:
		state = publishedimport.ImportPrepared
	case casestore.RemuxImportRequested:
		state = publishedimport.ImportRequested
	case casestore.RemuxImported:
		state = publishedimport.Imported
	case casestore.RemuxImportFailed:
		state = publishedimport.ImportFailed
	default:
		return publishedimport.Execution{}, fmt.Errorf(
			"remux state %q is not ready for import", execution.State,
		)
	}
	mapped := publishedimport.Execution{
		CaseID:       execution.CaseID(),
		State:        state,
		Import:       execution.Import,
		Confirmation: execution.Confirmation,
	}
	if execution.Published != nil {
		mapped.Published = &publishedimport.Artifact{
			RootID:         execution.Published.RootID,
			PathComponents: execution.Published.PathComponents,
		}
	}
	return mapped, nil
}
