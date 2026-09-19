package joinimport

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/publishedimport"
)

type Radarr = publishedimport.Radarr
type PublishedPathResolver = publishedimport.PublishedPathResolver
type Waiter = publishedimport.Waiter
type SubmissionUncertainError = publishedimport.SubmissionUncertainError

type Store interface {
	Get(string) (casestore.CaseRecord, bool, error)
	GetJoinExecution(string) (casestore.JoinExecution, bool, error)
	PrepareJoinImport(string, casestore.JoinImportRequest, time.Time) (casestore.JoinExecution, bool, error)
	MarkJoinImportRequested(string, int64, time.Time) (casestore.JoinExecution, bool, error)
	MarkJoinImported(string, controller.RadarrImportedFile, time.Time) (casestore.JoinExecution, bool, error)
	MarkJoinImportFailed(string, time.Time) (casestore.JoinExecution, bool, error)
}

type Dependencies struct {
	Radarr       Radarr
	Store        Store
	Paths        PublishedPathResolver
	Clock        controller.Clock
	Waiter       Waiter
	PollInterval time.Duration
}

type Executor struct {
	store Store
	core  *publishedimport.Executor
}

func New(dependencies Dependencies) (*Executor, error) {
	if dependencies.Store == nil {
		return nil, fmt.Errorf("joined-file import store is required")
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

func (executor *Executor) Execute(ctx context.Context, caseID string) (casestore.JoinExecution, error) {
	if executor == nil {
		return casestore.JoinExecution{}, fmt.Errorf("joined-file importer is not configured")
	}
	_, runErr := executor.core.Execute(ctx, caseID)
	execution, found, err := executor.store.GetJoinExecution(caseID)
	if err != nil {
		return casestore.JoinExecution{}, errors.Join(runErr, err)
	}
	if !found {
		return casestore.JoinExecution{}, errors.Join(runErr, fmt.Errorf("join is absent"))
	}
	return execution, runErr
}

type storeAdapter struct {
	Store
}

func (adapter *storeAdapter) GetExecution(caseID string) (publishedimport.Execution, bool, error) {
	execution, found, err := adapter.GetJoinExecution(caseID)
	if err != nil || !found {
		return publishedimport.Execution{}, found, err
	}
	mapped, err := asPublishedExecution(execution)
	return mapped, true, err
}

func (adapter *storeAdapter) PrepareImport(
	caseID string, request casestore.JoinImportRequest, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.PrepareJoinImport(caseID, request, at)
	return mapResult(execution, changed, err)
}

func (adapter *storeAdapter) MarkImportRequested(
	caseID string, commandID int64, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.MarkJoinImportRequested(caseID, commandID, at)
	return mapResult(execution, changed, err)
}

func (adapter *storeAdapter) MarkImported(
	caseID string, imported controller.RadarrImportedFile, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.MarkJoinImported(caseID, imported, at)
	return mapResult(execution, changed, err)
}

func (adapter *storeAdapter) MarkImportFailed(
	caseID string, at time.Time,
) (publishedimport.Execution, bool, error) {
	execution, changed, err := adapter.MarkJoinImportFailed(caseID, at)
	return mapResult(execution, changed, err)
}

func mapResult(
	execution casestore.JoinExecution, changed bool, err error,
) (publishedimport.Execution, bool, error) {
	if err != nil {
		return publishedimport.Execution{}, changed, err
	}
	mapped, err := asPublishedExecution(execution)
	return mapped, changed, err
}

func asPublishedExecution(execution casestore.JoinExecution) (publishedimport.Execution, error) {
	var state publishedimport.State
	switch execution.State {
	case casestore.JoinPublished:
		state = publishedimport.Published
	case casestore.JoinImportPrepared:
		state = publishedimport.ImportPrepared
	case casestore.JoinImportRequested:
		state = publishedimport.ImportRequested
	case casestore.JoinImported:
		state = publishedimport.Imported
	case casestore.JoinImportFailed:
		state = publishedimport.ImportFailed
	default:
		return publishedimport.Execution{}, fmt.Errorf(
			"join state %q is not ready for import", execution.State,
		)
	}
	mapped := publishedimport.Execution{
		CaseID:       execution.Authorization.CaseID,
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
