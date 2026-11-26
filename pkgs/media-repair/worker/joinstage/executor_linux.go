package joinstage

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/telemetry"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"github.com/booxter/nix-config/media-repair/worker/mediajoin"
	"go.opentelemetry.io/otel/attribute"
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
	message := failure.description()
	if failure.cause != nil {
		message += ": " + failure.cause.Error()
	}
	return message
}

func (failure *Failure) description() string {
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
	artifacts mediafile.StagedArtifacts
	joiner    mediajoin.Joiner
	prober    MediaProber
}

var (
	_ InputFiles                = (*mediafile.RootSet)(nil)
	_ mediafile.StagedArtifacts = (*mediafile.RootSet)(nil)
	_ MediaProber               = (*ffprobe.Runner)(nil)
)

func NewExecutor(
	inputs InputFiles,
	artifacts mediafile.StagedArtifacts,
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

func (executor *Executor) Stage(
	ctx context.Context,
	spec Specification,
) (result Result, returnedErr error) {
	if err := ctx.Err(); err != nil {
		return Result{}, failureFor(err, mediajoin.Diagnostics{})
	}
	if executor == nil || spec.ArtifactID == "" {
		return Result{}, &Failure{Reason: workercontracts.StageJoinInternalError}
	}

	parts, sourceBytes, err := executor.openParts(spec)
	if err != nil {
		return Result{}, err
	}
	defer closeFiles(parts)
	if sourceBytes != spec.ExpectedSourceBytes {
		return Result{}, &Failure{Reason: workercontracts.StageJoinSourceSizeMismatch}
	}

	// Normalized parts and the joined output coexist until validation finishes.
	phase, span := telemetry.StartPhase(ctx, "prepare staging", attribute.Int64("source_bytes", sourceBytes))
	artifact, err := executor.artifacts.CreateStaged(
		spec.RootID,
		spec.ArtifactID,
		spec.OutputContainer,
		2*spec.ExpectedSourceBytes,
	)
	telemetry.EndPhase(phase, span, err)
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
		spec.OutputContainer,
	)
	if err := executor.verifyParts(parts, spec.Parts); err != nil {
		return Result{}, err
	}
	if joinErr != nil {
		return Result{}, failureFor(joinErr, joinResult.Diagnostics)
	}

	phase, span = telemetry.StartPhase(ctx, "probe output metadata")
	evidence, probeErr := executor.prober.ProbeFile(phase, artifact.File())
	telemetry.EndPhase(phase, span, probeErr)
	if probeErr != nil {
		return Result{}, failureFor(probeErr, joinResult.Diagnostics)
	}
	if err := ctx.Err(); err != nil {
		return Result{}, failureFor(err, joinResult.Diagnostics)
	}
	phase, span = telemetry.StartPhase(ctx, "snapshot output")
	fingerprint, sizeBytes, err := artifact.Snapshot()
	telemetry.EndPhase(phase, span, err)
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

func (executor *Executor) openParts(
	specification Specification,
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
	specifications []Part,
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
