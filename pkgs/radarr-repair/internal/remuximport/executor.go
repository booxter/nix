package remuximport

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/joinimport"
)

// The published-file import workflow is shared with joins. This adapter maps
// remux state to that workflow without duplicating its uncertain-submission
// and Radarr history recovery rules.
type Store interface {
	Get(string) (casestore.CaseRecord, bool, error)
	GetRemuxExecution(string) (casestore.RemuxExecution, bool, error)
	PrepareRemuxImport(string, casestore.JoinImportRequest, time.Time) (casestore.RemuxExecution, bool, error)
	MarkRemuxImportRequested(string, int64, time.Time) (casestore.RemuxExecution, bool, error)
	MarkRemuxImported(string, controller.RadarrImportedFile, time.Time) (casestore.RemuxExecution, bool, error)
	MarkRemuxImportFailed(string, time.Time) (casestore.RemuxExecution, bool, error)
}

type Dependencies struct {
	Radarr       joinimport.Radarr
	Store        Store
	Paths        joinimport.PublishedPathResolver
	Clock        controller.Clock
	Waiter       joinimport.Waiter
	PollInterval time.Duration
}

type Executor struct {
	store Store
	core  *joinimport.Executor
}

func New(dependencies Dependencies) (*Executor, error) {
	if dependencies.Store == nil {
		return nil, fmt.Errorf("Blu-ray remux import store is required")
	}
	core, err := joinimport.New(joinimport.Dependencies{
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

func (adapter *storeAdapter) GetJoinExecution(caseID string) (casestore.JoinExecution, bool, error) {
	execution, found, err := adapter.GetRemuxExecution(caseID)
	if err != nil || !found {
		return casestore.JoinExecution{}, found, err
	}
	return asJoinExecution(execution)
}

func (adapter *storeAdapter) PrepareJoinImport(
	caseID string, request casestore.JoinImportRequest, at time.Time,
) (casestore.JoinExecution, bool, error) {
	execution, changed, err := adapter.PrepareRemuxImport(caseID, request, at)
	if err != nil {
		return casestore.JoinExecution{}, changed, err
	}
	joined, _, err := asJoinExecution(execution)
	return joined, changed, err
}

func (adapter *storeAdapter) MarkJoinImportRequested(
	caseID string, commandID int64, at time.Time,
) (casestore.JoinExecution, bool, error) {
	execution, changed, err := adapter.MarkRemuxImportRequested(caseID, commandID, at)
	if err != nil {
		return casestore.JoinExecution{}, changed, err
	}
	joined, _, err := asJoinExecution(execution)
	return joined, changed, err
}

func (adapter *storeAdapter) MarkJoinImported(
	caseID string, imported controller.RadarrImportedFile, at time.Time,
) (casestore.JoinExecution, bool, error) {
	execution, changed, err := adapter.MarkRemuxImported(caseID, imported, at)
	if err != nil {
		return casestore.JoinExecution{}, changed, err
	}
	joined, _, err := asJoinExecution(execution)
	return joined, changed, err
}

func (adapter *storeAdapter) MarkJoinImportFailed(
	caseID string, at time.Time,
) (casestore.JoinExecution, bool, error) {
	execution, changed, err := adapter.MarkRemuxImportFailed(caseID, at)
	if err != nil {
		return casestore.JoinExecution{}, changed, err
	}
	joined, _, err := asJoinExecution(execution)
	return joined, changed, err
}

func asJoinExecution(execution casestore.RemuxExecution) (casestore.JoinExecution, bool, error) {
	var state casestore.JoinExecutionState
	switch execution.State {
	case casestore.RemuxPublished:
		state = casestore.JoinPublished
	case casestore.RemuxImportPrepared:
		state = casestore.JoinImportPrepared
	case casestore.RemuxImportRequested:
		state = casestore.JoinImportRequested
	case casestore.RemuxImported:
		state = casestore.JoinImported
	case casestore.RemuxImportFailed:
		state = casestore.JoinImportFailed
	default:
		return casestore.JoinExecution{}, true, fmt.Errorf("remux state %q is not ready for import", execution.State)
	}
	joined := casestore.JoinExecution{
		Authorization: decisionpolicy.AuthorizedJoin{CaseID: execution.Authorization.CaseID},
		State:         state, Import: execution.Import, Confirmation: execution.Confirmation,
	}
	if execution.Published != nil {
		joined.Published = &casestore.JoinPublishedArtifact{
			RootID:         execution.Published.RootID,
			PathComponents: execution.Published.PathComponents,
		}
	}
	return joined, true, nil
}
