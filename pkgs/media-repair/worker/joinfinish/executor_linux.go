package joinfinish

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/joinstate"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
)

type Store interface {
	FindByArtifactID(string) (joinstate.Execution, bool, error)
	MarkPublished(
		string,
		string,
		string,
		joinstate.PublishedArtifact,
		time.Time,
	) (joinstate.Execution, bool, error)
	MarkDiscarded(
		string,
		string,
		string,
		time.Time,
	) (joinstate.Execution, bool, error)
}

type Artifacts interface {
	PublishCompleted(
		string,
		string,
		workercontracts.OutputContainer,
		string,
		[][]string,
	) ([]string, error)
	RemoveCompleted(
		string,
		string,
		workercontracts.OutputContainer,
		string,
	) (bool, error)
}

type Dependencies struct {
	Store     Store
	Artifacts Artifacts
	Clock     controller.Clock
}

type Executor struct {
	dependencies Dependencies
	finishSlot   chan struct{}
}

var (
	_ Store     = (*joinstate.Store)(nil)
	_ Artifacts = (*mediafile.RootSet)(nil)
)

func NewExecutor(dependencies Dependencies) (*Executor, error) {
	switch {
	case dependencies.Store == nil:
		return nil, fmt.Errorf("join state store is required")
	case dependencies.Artifacts == nil:
		return nil, fmt.Errorf("join artifact storage is required")
	case dependencies.Clock == nil:
		return nil, fmt.Errorf("clock is required")
	}
	return &Executor{
		dependencies: dependencies,
		finishSlot:   make(chan struct{}, 1),
	}, nil
}

func (executor *Executor) Publish(
	ctx context.Context,
	request workercontracts.PublishRequestV1,
) workercontracts.PublishResponseV1 {
	if executor == nil || ctx == nil {
		return publishFailure(request.RequestID, workercontracts.PublishInternalError)
	}
	if !executor.begin(ctx) {
		return publishFailure(request.RequestID, workercontracts.PublishErrorReason)
	}
	defer executor.end()

	execution, found, err := executor.dependencies.Store.FindByArtifactID(
		request.ArtifactID,
	)
	if err != nil {
		return publishFailure(request.RequestID, workercontracts.PublishInternalError)
	}
	if !found {
		return publishFailure(request.RequestID, workercontracts.PublishArtifactNotFound)
	}

	switch execution.State {
	case joinstate.Published:
		if !matchingFingerprint(execution, request.ArtifactFingerprint) {
			return publishFailure(
				request.RequestID,
				workercontracts.PublishArtifactFingerprintMismatch,
			)
		}
		return storedPublishSuccess(request.RequestID, execution)
	case joinstate.Staged:
		if !matchingFingerprint(execution, request.ArtifactFingerprint) {
			return publishFailure(
				request.RequestID,
				workercontracts.PublishArtifactFingerprintMismatch,
			)
		}
	default:
		return publishFailure(request.RequestID, workercontracts.PublishArtifactNotStaged)
	}

	paths := make([][]string, len(execution.Specification.Parts))
	for index, part := range execution.Specification.Parts {
		paths[index] = append([]string(nil), part.PathComponents...)
	}
	fingerprint := execution.Staged.Fingerprint
	publishedPath, err := executor.dependencies.Artifacts.PublishCompleted(
		execution.Specification.RootID,
		execution.ArtifactID,
		execution.Specification.OutputContainer,
		fingerprint,
		paths,
	)
	if err != nil {
		return publishFailure(request.RequestID, publishFailureReason(err))
	}

	published, _, err := executor.dependencies.Store.MarkPublished(
		execution.ExecutionID,
		execution.ArtifactID,
		fingerprint,
		joinstate.PublishedArtifact{
			RootID:         execution.Specification.RootID,
			PathComponents: publishedPath,
		},
		executor.dependencies.Clock.Now().UTC(),
	)
	if err != nil || published.State != joinstate.Published {
		return publishFailure(request.RequestID, workercontracts.PublishInternalError)
	}
	return storedPublishSuccess(request.RequestID, published)
}

func (executor *Executor) Discard(
	ctx context.Context,
	request workercontracts.DiscardRequestV1,
) workercontracts.DiscardResponseV1 {
	if executor == nil || ctx == nil {
		return discardFailure(request.RequestID, workercontracts.DiscardInternalError)
	}
	if !executor.begin(ctx) {
		return discardFailure(request.RequestID, workercontracts.DiscardErrorReason)
	}
	defer executor.end()

	execution, found, err := executor.dependencies.Store.FindByArtifactID(
		request.ArtifactID,
	)
	if err != nil {
		return discardFailure(request.RequestID, workercontracts.DiscardInternalError)
	}
	if !found {
		return discardFailure(request.RequestID, workercontracts.DiscardArtifactNotFound)
	}

	switch execution.State {
	case joinstate.Staged, joinstate.Published, joinstate.Discarded:
		if !matchingFingerprint(execution, request.ArtifactFingerprint) {
			return discardFailure(
				request.RequestID,
				workercontracts.DiscardArtifactFingerprintMismatch,
			)
		}
	default:
		return discardFailure(request.RequestID, workercontracts.DiscardArtifactNotFound)
	}
	if execution.State == joinstate.Published {
		return discardFailure(request.RequestID, workercontracts.DiscardArtifactPublished)
	}
	if execution.State == joinstate.Discarded {
		return discardSuccess(request.RequestID, execution)
	}

	fingerprint := execution.Staged.Fingerprint
	if _, err := executor.dependencies.Artifacts.RemoveCompleted(
		execution.Specification.RootID,
		execution.ArtifactID,
		execution.Specification.OutputContainer,
		fingerprint,
	); err != nil {
		return discardFailure(request.RequestID, discardFailureReason(err))
	}
	discarded, _, err := executor.dependencies.Store.MarkDiscarded(
		execution.ExecutionID,
		execution.ArtifactID,
		fingerprint,
		executor.dependencies.Clock.Now().UTC(),
	)
	if err != nil || discarded.State != joinstate.Discarded {
		return discardFailure(request.RequestID, workercontracts.DiscardInternalError)
	}
	return discardSuccess(request.RequestID, discarded)
}

func (executor *Executor) begin(ctx context.Context) bool {
	select {
	case executor.finishSlot <- struct{}{}:
		return true
	case <-ctx.Done():
		return false
	}
}

func (executor *Executor) end() {
	<-executor.finishSlot
}

func matchingFingerprint(execution joinstate.Execution, fingerprint string) bool {
	return execution.Staged != nil && execution.Staged.Fingerprint == fingerprint
}

func publishFailureReason(err error) workercontracts.PublishFailureReason {
	var failure *mediafile.Failure
	if !errors.As(err, &failure) {
		return workercontracts.PublishInternalError
	}
	switch failure.Kind {
	case mediafile.FailureFileUnavailable:
		return workercontracts.PublishArtifactNotFound
	case mediafile.FailureFingerprintMismatch:
		return workercontracts.PublishArtifactFingerprintMismatch
	case mediafile.FailureDestinationExists:
		return workercontracts.PublishDestinationExists
	case mediafile.FailureInternal:
		return workercontracts.PublishInternalError
	default:
		return workercontracts.PublishErrorReason
	}
}

func discardFailureReason(err error) workercontracts.DiscardFailureReason {
	var failure *mediafile.Failure
	if !errors.As(err, &failure) {
		return workercontracts.DiscardInternalError
	}
	switch failure.Kind {
	case mediafile.FailureFingerprintMismatch:
		return workercontracts.DiscardArtifactFingerprintMismatch
	case mediafile.FailureInternal:
		return workercontracts.DiscardInternalError
	default:
		return workercontracts.DiscardErrorReason
	}
}

func storedPublishSuccess(
	requestID string,
	execution joinstate.Execution,
) workercontracts.PublishResponseV1 {
	if execution.Staged == nil || execution.Published == nil ||
		execution.Published.RootID != execution.Specification.RootID {
		return publishFailure(requestID, workercontracts.PublishInternalError)
	}
	return workercontracts.PublishResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.PublishSuccessResponseV1{
			ArtifactFingerprint: execution.Staged.Fingerprint,
			ArtifactID:          execution.ArtifactID,
			Operation:           workercontracts.PublishV1,
			PathComponents: append(
				[]string(nil),
				execution.Published.PathComponents...,
			),
			RequestID:     requestID,
			RootID:        execution.Published.RootID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Ok,
		},
	}
}

func publishFailure(
	requestID string,
	reason workercontracts.PublishFailureReason,
) workercontracts.PublishResponseV1 {
	return workercontracts.PublishResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.PublishFailureResponseV1{
			Operation:     workercontracts.PublishV1,
			Reason:        reason,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}

func discardSuccess(
	requestID string,
	execution joinstate.Execution,
) workercontracts.DiscardResponseV1 {
	if execution.Staged == nil {
		return discardFailure(requestID, workercontracts.DiscardInternalError)
	}
	return workercontracts.DiscardResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.DiscardSuccessResponseV1{
			ArtifactFingerprint: execution.Staged.Fingerprint,
			ArtifactID:          execution.ArtifactID,
			Operation:           workercontracts.DiscardV1,
			RequestID:           requestID,
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
			Status:              workercontracts.Ok,
		},
	}
}

func discardFailure(
	requestID string,
	reason workercontracts.DiscardFailureReason,
) workercontracts.DiscardResponseV1 {
	return workercontracts.DiscardResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.DiscardFailureResponseV1{
			Operation:     workercontracts.DiscardV1,
			Reason:        reason,
			RequestID:     requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
}
