package operation

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/joinverification"
	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
	"github.com/booxter/nix-config/media-repair/internal/telemetry"
	"github.com/booxter/nix-config/media-repair/worker/bluraystage"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/dvdremux"
	"github.com/booxter/nix-config/media-repair/worker/dvdstage"
	"github.com/booxter/nix-config/media-repair/worker/joinstage"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"github.com/booxter/nix-config/media-repair/worker/mediajoin"
	"github.com/booxter/nix-config/media-repair/worker/mediaremux"
	"go.opentelemetry.io/otel/attribute"
)

type Transformer struct {
	Roots                   map[string]string
	Files                   *mediafile.RootSet
	Prober                  *ffprobe.Runner
	FFmpeg, MKVmerge, LSDVD string
	Timeout                 time.Duration
}

func (worker Transformer) Transform(ctx context.Context, request mediaoperation.Transform) (output mediaoperation.Output, returnedErr error) {
	ctx, span := telemetry.StartPhase(ctx, "transform",
		attribute.Int64("job", request.JobID), attribute.Int64("attempt", request.Attempt),
		attribute.Float64("timeout_seconds", worker.Timeout.Seconds()))
	defer func() { telemetry.EndPhase(ctx, span, returnedErr) }()
	if request.JobID <= 0 || request.Attempt <= 0 {
		return mediaoperation.Output{}, fmt.Errorf("job and attempt must be positive")
	}

	count := 0
	for _, selected := range []bool{request.Join != nil, request.Bluray != nil, request.DVD != nil} {
		if selected {
			count++
		}
	}
	if count != 1 {
		return mediaoperation.Output{}, fmt.Errorf("select exactly one media operation")
	}

	if request.Join != nil {
		span.SetAttributes(attribute.Int64("source_bytes", request.Join.SourceBytes), attribute.Int("parts", len(request.Join.OrderedParts)))
		return worker.join(ctx, request)
	}
	if request.Bluray != nil {
		return worker.bluray(ctx, request)
	}

	return worker.dvd(ctx, request)
}

func (worker Transformer) join(ctx context.Context, request mediaoperation.Transform) (mediaoperation.Output, error) {
	authorized := *request.Join
	containers := []workercontracts.OutputContainer{workercontracts.OutputContainerMKV}
	switch authorized.OutputContainer {
	case controller.OutputContainerMKV:
	case controller.OutputContainerAVI, controller.OutputContainerMP4:
		containers = append(containers, workercontracts.OutputContainer(authorized.OutputContainer))
	default:
		return mediaoperation.Output{}, fmt.Errorf("unsupported join container %q", authorized.OutputContainer)
	}

	paths := make([]string, len(authorized.OrderedParts))
	for i, part := range authorized.OrderedParts {
		paths[i] = request.Paths[part.FileID]
	}

	root, components, err := worker.resolve(paths)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	spec := joinstage.Specification{
		ArtifactID:          request.ID(),
		RootID:              root,
		ExpectedSourceBytes: authorized.SourceBytes,
	}
	for i, part := range authorized.OrderedParts {
		spec.Parts = append(spec.Parts, joinstage.Part{
			PathComponents:      components[i],
			ExpectedFingerprint: part.Fingerprint.StrictFingerprint(),
		})
	}

	joiner, err := mediajoin.NewRunner(worker.FFmpeg, worker.Timeout, worker.Prober)
	if err != nil {
		return mediaoperation.Output{}, err
	}
	stager, err := joinstage.NewExecutor(worker.Files, worker.Files, joiner, worker.Prober)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	var failures error
	for _, container := range containers {
		spec.OutputContainer = container
		authorized.OutputContainer = controller.OutputContainer(container)
		phase, span := telemetry.StartPhase(ctx, "join output", attribute.String("container", string(container)))
		result, err := worker.stageJoin(phase, stager, spec, authorized)
		telemetry.EndPhase(phase, span, err)
		if err != nil {
			failures = errors.Join(failures, fmt.Errorf("%s join: %w", container, err))
			if ctx.Err() != nil || !canTryAnotherJoinContainer(err) {
				break
			}
			continue
		}

		phase, span = telemetry.StartPhase(ctx, "publish output")
		published, err := worker.Files.PublishCompleted(root, request.ID(), container, result.Fingerprint, components)
		telemetry.EndPhase(phase, span, err)
		if err != nil {
			return mediaoperation.Output{}, err
		}
		return worker.output(root, published)
	}
	return mediaoperation.Output{}, failures
}

var errJoinOutputRejected = errors.New("joined output rejected")

func (worker Transformer) stageJoin(
	ctx context.Context, stager *joinstage.Executor, spec joinstage.Specification, authorized decisionpolicy.AuthorizedJoin,
) (joinstage.Result, error) {
	result, err := stager.Stage(ctx, spec)
	if err != nil {
		return joinstage.Result{}, err
	}

	phase, span := telemetry.StartPhase(ctx, "validate output metadata", attribute.Int64("output_bytes", result.SizeBytes))
	rejected := joinverification.ValidateOutput(authorized, result.Evidence, result.SizeBytes)
	if len(rejected) == 0 {
		telemetry.EndPhase(phase, span, nil)
		return result, nil
	}

	rejection := fmt.Errorf("%w: %v", errJoinOutputRejected, rejected)
	telemetry.EndPhase(phase, span, rejection)
	if _, err := worker.Files.RemoveCompleted(spec.RootID, spec.ArtifactID, spec.OutputContainer, result.Fingerprint); err != nil {
		return joinstage.Result{}, fmt.Errorf("%v; discard: %w", rejection, err)
	}
	return joinstage.Result{}, rejection
}

func canTryAnotherJoinContainer(err error) bool {
	if errors.Is(err, errJoinOutputRejected) {
		return true
	}
	var failure *joinstage.Failure
	var pathError *os.PathError
	return errors.As(err, &failure) && !errors.As(err, &pathError) &&
		(failure.Reason == workercontracts.StageJoinJoinError || failure.Reason == workercontracts.StageJoinInvalidOutput)
}

func (worker Transformer) bluray(ctx context.Context, request mediaoperation.Transform) (mediaoperation.Output, error) {
	authorized := *request.Bluray
	sources := append([]decisionpolicy.AuthorizedRemuxFile{authorized.Playlist}, authorized.Clips...)
	root, components, err := worker.sourcePaths(sources, request.Paths)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	spec := bluraystage.Specification{
		ExecutionID:          request.ID(),
		CaseID:               authorized.CaseID,
		CapabilityID:         authorized.CapabilityID,
		RootID:               root,
		ExpectedDurationMS:   authorized.ExpectedDurationMS,
		ExpectedChapterCount: int(authorized.ExpectedChapters),
		ExpectedTracks:       authorized.ExpectedTracks,
	}
	for i, source := range sources {
		part := bluraystage.Source{
			PathComponents:      components[i],
			ExpectedFingerprint: source.Fingerprint.StrictFingerprint(),
			SizeBytes:           source.Fingerprint.SizeBytes,
		}
		if i == 0 {
			spec.Playlist = part
		} else {
			spec.Clips = append(spec.Clips, part)
		}
	}

	remuxer, err := mediaremux.NewRunner(worker.MKVmerge, worker.Timeout)
	if err != nil {
		return mediaoperation.Output{}, err
	}
	stager, err := bluraystage.NewExecutor(
		worker.Files, worker.Files, mkvmerge.Runner{Executable: worker.MKVmerge}, remuxer, worker.Prober,
	)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	result, err := stager.Stage(ctx, spec)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	directory := spec.Playlist.PathComponents[:len(spec.Playlist.PathComponents)-3]
	published, err := worker.Files.PublishCompletedAt(root, result.ArtifactID, workercontracts.OutputContainerMKV, result.Fingerprint, directory)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	return worker.output(root, published)
}

func (worker Transformer) dvd(ctx context.Context, request mediaoperation.Transform) (mediaoperation.Output, error) {
	selection := request.DVD
	if len(selection.Titles) == 0 || len(selection.Titles) > 128 ||
		selection.MovieRuntimeMS <= 0 || selection.RuntimeToleranceMS <= 0 {
		return mediaoperation.Output{}, fmt.Errorf("DVD title selection and movie runtime are required")
	}

	remuxer, err := dvdremux.NewRunner(worker.FFmpeg, worker.Timeout)
	if err != nil {
		return mediaoperation.Output{}, err
	}
	stager, err := dvdstage.NewExecutor(
		worker.Files, worker.Files, dvdvideo.Runner{Executable: worker.LSDVD}, remuxer, worker.Prober,
	)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	specs := make([]dvdstage.Specification, 0, len(selection.Titles))
	for _, title := range selection.Titles {
		spec, err := worker.dvdSpecification(request, title)
		if err != nil {
			return mediaoperation.Output{}, err
		}
		if len(specs) != 0 && spec.RootID != specs[0].RootID {
			return mediaoperation.Output{}, fmt.Errorf("DVD titles must share a configured root")
		}
		specs = append(specs, spec)
	}

	root := specs[0].RootID
	var result dvdstage.Result
	if len(specs) == 1 {
		result, err = stager.Stage(ctx, specs[0])
	} else {
		result, err = worker.joinDVD(ctx, request, stager, specs)
	}
	if err != nil {
		return mediaoperation.Output{}, err
	}

	duration := result.Evidence.Format.DurationMS
	if duration == nil || *duration <= 0 ||
		*duration-selection.MovieRuntimeMS > selection.RuntimeToleranceMS ||
		selection.MovieRuntimeMS-*duration > selection.RuntimeToleranceMS {
		_, removeErr := worker.Files.RemoveCompleted(root, result.ArtifactID,
			workercontracts.OutputContainerMKV, result.Fingerprint)
		return mediaoperation.Output{}, errors.Join(fmt.Errorf("DVD output runtime outside movie tolerance"), removeErr)
	}

	published, err := worker.Files.PublishCompletedAt(root, result.ArtifactID,
		workercontracts.OutputContainerMKV, result.Fingerprint, dvdOutputDirectory(specs))
	if err != nil {
		return mediaoperation.Output{}, err
	}

	return worker.output(root, published)
}

func (worker Transformer) dvdSpecification(
	request mediaoperation.Transform, authorized decisionpolicy.AuthorizedDVD,
) (dvdstage.Specification, error) {
	sources := append([]decisionpolicy.AuthorizedRemuxFile{authorized.Navigation}, authorized.Sources...)
	root, components, err := worker.sourcePaths(sources, request.Paths)
	if err != nil {
		return dvdstage.Specification{}, err
	}

	spec := dvdstage.Specification{
		ExecutionID:          request.ID(),
		CaseID:               authorized.CaseID,
		CapabilityID:         authorized.CapabilityID,
		RootID:               root,
		TitleNumber:          authorized.TitleNumber,
		ExpectedDurationMS:   authorized.ExpectedDurationMS,
		ExpectedChapterCount: authorized.ExpectedChapters,
		ExpectedTracks:       authorized.ExpectedTracks,
	}
	for i, source := range sources {
		part := dvdstage.Source{
			PathComponents:      components[i],
			ExpectedFingerprint: source.Fingerprint.StrictFingerprint(),
			SizeBytes:           source.Fingerprint.SizeBytes,
		}
		if i == 0 {
			spec.Navigation = part
		} else {
			spec.Sources = append(spec.Sources, part)
		}
	}

	return spec, nil
}

func (worker Transformer) sourcePaths(sources []decisionpolicy.AuthorizedRemuxFile, paths map[controller.FileID]string) (string, [][]string, error) {
	selected := make([]string, len(sources))
	for i, source := range sources {
		selected[i] = paths[source.FileID]
	}

	return worker.resolve(selected)
}

func (worker Transformer) resolve(paths []string) (string, [][]string, error) {
	rootIDs := make([]string, 0, len(worker.Roots))
	for id := range worker.Roots {
		rootIDs = append(rootIDs, id)
	}
	slices.Sort(rootIDs)

	for _, id := range rootIDs {
		var components [][]string
		for _, path := range paths {
			relative, err := filepath.Rel(worker.Roots[id], path)
			if err != nil || !filepath.IsAbs(path) || !filepath.IsLocal(relative) || relative == "." {
				break
			}
			components = append(components, strings.Split(relative, string(filepath.Separator)))
		}
		if len(components) == len(paths) && len(paths) != 0 {
			return id, components, nil
		}
	}

	return "", nil, fmt.Errorf("media inputs must share a configured root")
}

func (worker Transformer) output(root string, components []string) (mediaoperation.Output, error) {
	path, err := worker.Files.AbsolutePath(root, components)
	return mediaoperation.Output{Path: path}, err
}
