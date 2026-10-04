package operation

import (
	"context"
	"fmt"
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
	"github.com/booxter/nix-config/media-repair/worker/bluraystage"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/dvdremux"
	"github.com/booxter/nix-config/media-repair/worker/dvdstage"
	"github.com/booxter/nix-config/media-repair/worker/joinstage"
	"github.com/booxter/nix-config/media-repair/worker/joinstate"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"github.com/booxter/nix-config/media-repair/worker/mediajoin"
	"github.com/booxter/nix-config/media-repair/worker/mediaremux"
)

type Transformer struct {
	Roots                   map[string]string
	Files                   *mediafile.RootSet
	Prober                  *ffprobe.Runner
	FFmpeg, MKVmerge, LSDVD string
	Timeout                 time.Duration
}

func (worker Transformer) Transform(ctx context.Context, request mediaoperation.Transform) (mediaoperation.Output, error) {
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
		return worker.join(ctx, request)
	}
	if request.Bluray != nil {
		return worker.bluray(ctx, request)
	}

	return worker.dvd(ctx, request)
}

func (worker Transformer) join(ctx context.Context, request mediaoperation.Transform) (mediaoperation.Output, error) {
	authorized := *request.Join
	paths := make([]string, len(authorized.OrderedParts))
	for i, part := range authorized.OrderedParts {
		paths[i] = request.Paths[part.FileID]
	}

	root, components, err := worker.resolve(paths)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	spec := joinstate.Specification{
		RootID:              root,
		OutputContainer:     workercontracts.OutputContainer(authorized.OutputContainer),
		ExpectedSourceBytes: authorized.SourceBytes,
	}
	for i, part := range authorized.OrderedParts {
		spec.Parts = append(spec.Parts, joinstate.Part{
			FileID:              string(part.FileID),
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

	result, err := stager.Stage(ctx, joinstate.Execution{
		State:         joinstate.Prepared,
		ArtifactID:    request.ID(),
		Specification: spec,
	})
	if err != nil {
		return mediaoperation.Output{}, err
	}

	// An ffmpeg exit status is not sufficient: only validated output may
	// become visible to Servarr. Sources remain untouched in either case.
	if rejected := joinverification.ValidateOutput(authorized, result.Evidence, result.SizeBytes); len(rejected) != 0 {
		if _, err := worker.Files.RemoveCompleted(root, request.ID(), spec.OutputContainer, result.Fingerprint); err != nil {
			return mediaoperation.Output{}, fmt.Errorf("rejected output %v; discard: %w", rejected, err)
		}

		return mediaoperation.Output{}, fmt.Errorf("joined output rejected: %v", rejected)
	}

	published, err := worker.Files.PublishCompleted(root, request.ID(), spec.OutputContainer, result.Fingerprint, components)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	return worker.output(root, published, result.Fingerprint, result.Evidence)
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

	result, err := stager.StageOrRecover(ctx, spec)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	directory := spec.Playlist.PathComponents[:len(spec.Playlist.PathComponents)-3]
	published, err := worker.Files.PublishCompletedAt(root, result.ArtifactID, workercontracts.OutputContainerMKV, result.Fingerprint, directory)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	return worker.output(root, published, result.Fingerprint, result.Evidence)
}

func (worker Transformer) dvd(ctx context.Context, request mediaoperation.Transform) (mediaoperation.Output, error) {
	authorized := *request.DVD
	sources := append([]decisionpolicy.AuthorizedRemuxFile{authorized.Navigation}, authorized.Sources...)
	root, components, err := worker.sourcePaths(sources, request.Paths)
	if err != nil {
		return mediaoperation.Output{}, err
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

	result, err := stager.StageOrRecover(ctx, spec)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	directory := spec.Navigation.PathComponents[:len(spec.Navigation.PathComponents)-1]
	if len(directory) > 0 && directory[len(directory)-1] == "VIDEO_TS" {
		directory = directory[:len(directory)-1]
	}
	published, err := worker.Files.PublishCompletedAt(root, result.ArtifactID, workercontracts.OutputContainerMKV, result.Fingerprint, directory)
	if err != nil {
		return mediaoperation.Output{}, err
	}

	return worker.output(root, published, result.Fingerprint, result.Evidence)
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

func (worker Transformer) output(root string, components []string, fingerprint string, evidence controller.ProbeEvidence) (mediaoperation.Output, error) {
	path, err := worker.Files.AbsolutePath(root, components)
	return mediaoperation.Output{Path: path, Fingerprint: fingerprint, Evidence: evidence}, err
}
