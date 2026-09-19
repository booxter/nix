package joinstage

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstate"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	"github.com/booxter/nix-config/radarr-repair/worker/mediajoin"
)

type InputFiles interface {
	Open(string, []string, string) (*os.File, error)
	Verify(*os.File, string) error
}

type MediaProber interface {
	ProbeFile(context.Context, *os.File) (controller.ProbeEvidence, error)
}

type Result struct {
	Fingerprint string
	SizeBytes   int64
	Evidence    controller.ProbeEvidence
	Diagnostics mediajoin.Diagnostics
}

type Failure struct {
	Reason      workercontracts.StageJoinFailureReason
	Diagnostics mediajoin.Diagnostics
	cause       error
}

func (failure *Failure) Error() string {
	switch failure.Reason {
	case workercontracts.StageJoinUnknownRoot:
		return "join input root is unknown"
	case workercontracts.StageJoinInvalidPath:
		return "join input path is invalid"
	case workercontracts.StageJoinFileUnavailable:
		return "join input is unavailable"
	case workercontracts.StageJoinNotRegularFile:
		return "join input is not a regular file"
	case workercontracts.StageJoinFingerprintMismatch:
		return "join input fingerprint changed"
	case workercontracts.StageJoinSourceSizeMismatch:
		return "join input size does not match the authorized size"
	case workercontracts.StageJoinInsufficientSpace:
		return "insufficient space for joined media"
	case workercontracts.StageJoinExecutionConflict:
		return "joined media artifact already exists"
	case workercontracts.StageJoinJoinError:
		return "media join failed"
	case workercontracts.StageJoinTimeout:
		return "media join or probe timed out"
	case workercontracts.StageJoinProbeError:
		return "joined media probe failed"
	case workercontracts.StageJoinInvalidOutput:
		return "media join produced invalid output"
	default:
		return "media join staging failed"
	}
}

func (failure *Failure) Unwrap() error {
	return failure.cause
}

type Executor struct {
	inputs    InputFiles
	artifacts mediafile.RecoverableStagedArtifacts
	joiner    mediajoin.Joiner
	prober    MediaProber
}

var (
	_ InputFiles                           = (*mediafile.RootSet)(nil)
	_ mediafile.RecoverableStagedArtifacts = (*mediafile.RootSet)(nil)
	_ MediaProber                          = (*ffprobe.Runner)(nil)
)

func NewExecutor(
	inputs InputFiles,
	artifacts mediafile.RecoverableStagedArtifacts,
	joiner mediajoin.Joiner,
	prober MediaProber,
) (*Executor, error) {
	if inputs == nil {
		return nil, fmt.Errorf("join input access is required")
	}
	if artifacts == nil {
		return nil, fmt.Errorf("join artifact storage is required")
	}
	if joiner == nil {
		return nil, fmt.Errorf("media joiner is required")
	}
	if prober == nil {
		return nil, fmt.Errorf("joined media prober is required")
	}
	return &Executor{
		inputs: inputs, artifacts: artifacts, joiner: joiner, prober: prober,
	}, nil
}

func (executor *Executor) StageOrRecover(
	ctx context.Context,
	execution joinstate.Execution,
) (Result, error) {
	if err := validateExecution(ctx, executor, execution); err != nil {
		return Result{}, err
	}
	completed, err := mediafile.PrepareStage(
		executor.artifacts,
		execution.Specification.RootID,
		execution.ArtifactID,
		execution.Specification.OutputContainer,
	)
	if err != nil {
		return Result{}, failureFor(err, mediajoin.Diagnostics{})
	}
	if completed != nil {
		return executor.recoverCompleted(ctx, execution, completed)
	}
	return executor.Stage(ctx, execution)
}

func (executor *Executor) Stage(
	ctx context.Context,
	execution joinstate.Execution,
) (result Result, returnedErr error) {
	if err := validateExecution(ctx, executor, execution); err != nil {
		return Result{}, err
	}

	parts, sourceBytes, err := executor.openParts(execution.Specification)
	if err != nil {
		return Result{}, err
	}
	defer closeFiles(parts)
	if sourceBytes != execution.Specification.ExpectedSourceBytes {
		return Result{}, &Failure{Reason: workercontracts.StageJoinSourceSizeMismatch}
	}

	artifact, err := executor.artifacts.CreateStaged(
		execution.Specification.RootID,
		execution.ArtifactID,
		execution.Specification.OutputContainer,
		execution.Specification.ExpectedSourceBytes,
	)
	if err != nil {
		return Result{}, failureFor(err, mediajoin.Diagnostics{})
	}
	retained := false
	defer func() {
		if retained {
			return
		}
		if err := artifact.Discard(); err != nil {
			result = Result{}
			returnedErr = &Failure{
				Reason: workercontracts.StageJoinInternalError,
				cause:  errors.Join(returnedErr, err),
			}
		}
	}()

	joinResult, joinErr := executor.joiner.Join(
		ctx,
		parts,
		artifact.File(),
		execution.Specification.OutputContainer,
	)
	if err := executor.verifyParts(parts, execution.Specification.Parts); err != nil {
		return Result{}, err
	}
	if joinErr != nil {
		return Result{}, failureFor(joinErr, joinResult.Diagnostics)
	}

	evidence, probeErr := executor.prober.ProbeFile(ctx, artifact.File())
	if probeErr != nil {
		return Result{}, failureFor(probeErr, joinResult.Diagnostics)
	}
	if err := ctx.Err(); err != nil {
		return Result{}, failureFor(err, joinResult.Diagnostics)
	}
	fingerprint, sizeBytes, err := artifact.Snapshot()
	if err != nil {
		return Result{}, failureFor(err, joinResult.Diagnostics)
	}
	if sizeBytes <= 0 || sizeBytes != joinResult.SizeBytes {
		return Result{}, &Failure{
			Reason:      workercontracts.StageJoinInvalidOutput,
			Diagnostics: joinResult.Diagnostics,
		}
	}
	if err := artifact.Retain(); err != nil {
		return Result{}, failureFor(err, joinResult.Diagnostics)
	}
	retained = true
	return Result{
		Fingerprint: fingerprint,
		SizeBytes:   sizeBytes,
		Evidence:    evidence,
		Diagnostics: joinResult.Diagnostics,
	}, nil
}

func (executor *Executor) recoverCompleted(
	ctx context.Context,
	execution joinstate.Execution,
	artifact mediafile.CompletedArtifact,
) (Result, error) {
	fingerprintBefore, sizeBefore, initialErr := artifact.Snapshot()
	var evidence controller.ProbeEvidence
	var probeErr error
	if initialErr == nil && sizeBefore > 0 {
		evidence, probeErr = executor.prober.ProbeFile(ctx, artifact.File())
	}
	fingerprintAfter, sizeAfter, finalErr := artifact.Snapshot()
	closeErr := artifact.Close()

	var recoveryErr error
	switch {
	case initialErr != nil:
		recoveryErr = initialErr
	case sizeBefore <= 0:
		recoveryErr = &Failure{Reason: workercontracts.StageJoinInvalidOutput}
	case probeErr != nil:
		recoveryErr = failureFor(probeErr, mediajoin.Diagnostics{})
	case finalErr != nil:
		recoveryErr = finalErr
	case fingerprintBefore != fingerprintAfter || sizeBefore != sizeAfter:
		recoveryErr = &Failure{Reason: workercontracts.StageJoinInvalidOutput}
	case closeErr != nil:
		recoveryErr = closeErr
	case ctx.Err() != nil:
		recoveryErr = ctx.Err()
	}
	if recoveryErr == nil {
		return Result{
			Fingerprint: fingerprintAfter,
			SizeBytes:   sizeAfter,
			Evidence:    evidence,
		}, nil
	}
	if finalErr != nil || fingerprintAfter == "" {
		return Result{}, failureFor(
			errors.Join(recoveryErr, closeErr),
			mediajoin.Diagnostics{},
		)
	}
	removed, removeErr := executor.artifacts.RemoveCompleted(
		execution.Specification.RootID,
		execution.ArtifactID,
		execution.Specification.OutputContainer,
		fingerprintAfter,
	)
	if removeErr != nil || !removed {
		return Result{}, &Failure{
			Reason: workercontracts.StageJoinInternalError,
			cause:  errors.Join(recoveryErr, closeErr, removeErr),
		}
	}
	return Result{}, failureFor(
		errors.Join(recoveryErr, closeErr),
		mediajoin.Diagnostics{},
	)
}

func validateExecution(
	ctx context.Context,
	executor *Executor,
	execution joinstate.Execution,
) error {
	if err := ctx.Err(); err != nil {
		return failureFor(err, mediajoin.Diagnostics{})
	}
	if executor == nil || execution.State != joinstate.Prepared ||
		execution.ArtifactID == "" {
		return &Failure{Reason: workercontracts.StageJoinInternalError}
	}
	return nil
}

func (executor *Executor) openParts(
	specification joinstate.Specification,
) ([]*os.File, int64, error) {
	parts := make([]*os.File, 0, len(specification.Parts))
	var total int64
	for _, part := range specification.Parts {
		media, err := executor.inputs.Open(
			specification.RootID,
			part.PathComponents,
			part.ExpectedFingerprint,
		)
		if err != nil {
			closeFiles(parts)
			return nil, 0, failureFor(err, mediajoin.Diagnostics{})
		}
		if media == nil {
			closeFiles(parts)
			return nil, 0, &Failure{Reason: workercontracts.StageJoinInternalError}
		}
		info, err := media.Stat()
		if err != nil {
			_ = media.Close()
			closeFiles(parts)
			return nil, 0, &Failure{
				Reason: workercontracts.StageJoinFileUnavailable,
				cause:  err,
			}
		}
		if info.Size() < 0 || total > math.MaxInt64-info.Size() {
			_ = media.Close()
			closeFiles(parts)
			return nil, 0, &Failure{Reason: workercontracts.StageJoinInternalError}
		}
		total += info.Size()
		parts = append(parts, media)
	}
	return parts, total, nil
}

func (executor *Executor) verifyParts(
	parts []*os.File,
	specifications []joinstate.Part,
) error {
	if len(parts) != len(specifications) {
		return &Failure{Reason: workercontracts.StageJoinInternalError}
	}
	for index, part := range parts {
		if err := executor.inputs.Verify(
			part,
			specifications[index].ExpectedFingerprint,
		); err != nil {
			return failureFor(err, mediajoin.Diagnostics{})
		}
	}
	return nil
}

func closeFiles(files []*os.File) {
	for _, file := range files {
		_ = file.Close()
	}
}

func failureFor(err error, diagnostics mediajoin.Diagnostics) error {
	var stageFailure *Failure
	if errors.As(err, &stageFailure) {
		return &Failure{
			Reason:      stageFailure.Reason,
			Diagnostics: stageFailure.Diagnostics,
			cause:       err,
		}
	}

	var fileFailure *mediafile.Failure
	if errors.As(err, &fileFailure) {
		reason := workercontracts.StageJoinInternalError
		switch fileFailure.Kind {
		case mediafile.FailureUnknownRoot:
			reason = workercontracts.StageJoinUnknownRoot
		case mediafile.FailureInvalidPath:
			reason = workercontracts.StageJoinInvalidPath
		case mediafile.FailureFileUnavailable:
			reason = workercontracts.StageJoinFileUnavailable
		case mediafile.FailureNotRegularFile:
			reason = workercontracts.StageJoinNotRegularFile
		case mediafile.FailureFingerprintMismatch:
			reason = workercontracts.StageJoinFingerprintMismatch
		case mediafile.FailureInsufficientSpace:
			reason = workercontracts.StageJoinInsufficientSpace
		case mediafile.FailureArtifactExists:
			reason = workercontracts.StageJoinExecutionConflict
		}
		return &Failure{Reason: reason, Diagnostics: diagnostics, cause: err}
	}

	var joinFailure *mediajoin.Failure
	if errors.As(err, &joinFailure) {
		diagnostics = joinFailure.Diagnostics
		reason := workercontracts.StageJoinJoinError
		switch joinFailure.Kind {
		case mediajoin.FailureTimeout:
			reason = workercontracts.StageJoinTimeout
		case mediajoin.FailureInvalidOutput:
			reason = workercontracts.StageJoinInvalidOutput
		}
		return &Failure{Reason: reason, Diagnostics: diagnostics, cause: err}
	}

	var probeFailure *ffprobe.Failure
	if errors.As(err, &probeFailure) {
		reason := workercontracts.StageJoinProbeError
		switch probeFailure.Kind {
		case ffprobe.FailureTimeout:
			reason = workercontracts.StageJoinTimeout
		case ffprobe.FailureInvalidOutput:
			reason = workercontracts.StageJoinInvalidOutput
		}
		return &Failure{Reason: reason, Diagnostics: diagnostics, cause: err}
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return &Failure{
			Reason: workercontracts.StageJoinTimeout, Diagnostics: diagnostics, cause: err,
		}
	}
	return &Failure{
		Reason: workercontracts.StageJoinInternalError, Diagnostics: diagnostics, cause: err,
	}
}
