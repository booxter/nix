package operation

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"math"
	"os"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
	"github.com/booxter/nix-config/media-repair/internal/remuxverification"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/dvdstage"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"github.com/booxter/nix-config/media-repair/worker/mediajoin"
)

func (worker Transformer) joinDVD(
	ctx context.Context, request mediaoperation.Transform, stager *dvdstage.Executor,
	specs []dvdstage.Specification,
) (result dvdstage.Result, returnedErr error) {
	root := specs[0].RootID
	container := workercontracts.OutputContainerMKV
	artifacts := make([]mediafile.CompletedArtifact, 0, len(specs))
	parts := make([]*os.File, 0, len(specs))
	staged := make([]dvdstage.Result, 0, len(specs))
	var sourceBytes int64
	for index, spec := range specs {
		part, err := stager.Stage(ctx, spec)
		if err != nil {
			return result, fmt.Errorf("remux DVD title %d: %w", index+1, err)
		}
		defer func() {
			_, err := worker.Files.RemoveCompleted(root, part.ArtifactID, container, part.Fingerprint)
			returnedErr = errors.Join(returnedErr, err)
		}()
		artifact, err := worker.openDVDPart(root, part)
		if err != nil {
			return result, fmt.Errorf("open DVD title %d: %w", index+1, err)
		}
		defer func() { returnedErr = errors.Join(returnedErr, artifact.Close()) }()
		artifacts = append(artifacts, artifact)
		parts = append(parts, artifact.File())
		staged = append(staged, part)
		if part.SizeBytes > math.MaxInt64/2-sourceBytes {
			return result, fmt.Errorf("DVD join sources exceed staging limits")
		}
		sourceBytes += part.SizeBytes
	}

	metadata, layout, err := dvdJoinMetadata(staged)
	if err != nil {
		return result, err
	}
	joiner, err := mediajoin.NewRunner(worker.FFmpeg, worker.Timeout, worker.Prober)
	if err != nil {
		return result, err
	}

	ids := make([]string, 0, len(staged)+1)
	ids = append(ids, request.ID())
	for _, part := range staged {
		ids = append(ids, part.ArtifactID)
	}
	artifactID := fmt.Sprintf("dvd-join:%x", sha256.Sum256([]byte(strings.Join(ids, "\n"))))
	// Normalized inputs and the final output coexist while FFmpeg joins them.
	output, err := worker.Files.CreateStaged(root, artifactID, container, 2*sourceBytes)
	if err != nil {
		return result, err
	}
	retained := false
	defer func() {
		if !retained {
			returnedErr = errors.Join(returnedErr, output.Discard())
		}
	}()

	joined, err := joiner.JoinDVD(ctx, parts, output.File(), metadata)
	if err != nil {
		return result, err
	}
	for index, part := range artifacts {
		fingerprint, size, err := part.Snapshot()
		if err != nil || fingerprint != staged[index].Fingerprint || size != staged[index].SizeBytes {
			return result, errors.Join(fmt.Errorf("remuxed DVD title %d changed during join", index+1), err)
		}
	}
	probe, err := worker.Prober.ProbeFile(ctx, output.File())
	if err != nil {
		return result, err
	}
	if err := validateJoinedDVD(specs[0], metadata, layout, staged[0].Evidence, probe); err != nil {
		return result, err
	}
	fingerprint, size, err := output.Snapshot()
	if err != nil || size != joined.SizeBytes {
		return result, errors.Join(fmt.Errorf("joined DVD changed after probing"), err)
	}
	if err := output.Retain(); err != nil {
		return result, err
	}
	retained = true
	return dvdstage.Result{
		ArtifactID: artifactID, Fingerprint: fingerprint, SizeBytes: size, Evidence: probe,
	}, nil
}

func (worker Transformer) openDVDPart(root string, part dvdstage.Result) (mediafile.CompletedArtifact, error) {
	status, artifact, err := worker.Files.InspectStaged(root, part.ArtifactID, workercontracts.OutputContainerMKV)
	if err != nil {
		return nil, err
	}
	if status != mediafile.StagedComplete {
		return nil, fmt.Errorf("remuxed DVD title is missing")
	}
	fingerprint, size, err := artifact.Snapshot()
	if err != nil || fingerprint != part.Fingerprint || size != part.SizeBytes {
		return nil, errors.Join(fmt.Errorf("remuxed DVD title changed before join"), err, artifact.Close())
	}
	return artifact, nil
}

func dvdJoinMetadata(parts []dvdstage.Result) ([]mediajoin.PartMetadata, controller.StreamLayout, error) {
	probes := make([]controller.ProbeEvidence, 0, len(parts))
	metadata := make([]mediajoin.PartMetadata, 0, len(parts))
	for index, part := range parts {
		probe := part.Evidence
		if probe.Format.DurationMS == nil || *probe.Format.DurationMS <= 0 {
			return nil, controller.StreamLayout{}, fmt.Errorf("remuxed DVD title %d is missing duration", index+1)
		}
		duration := *probe.Format.DurationMS
		chapters, err := dvdPartChapters(probe.Chapters, duration)
		if err != nil {
			return nil, controller.StreamLayout{}, fmt.Errorf("remuxed DVD title %d: %w", index+1, err)
		}
		probes = append(probes, probe)
		metadata = append(metadata, mediajoin.PartMetadata{DurationMS: duration, Chapters: chapters})
	}

	compatibility := controller.AssessStreamCompatibility(probes)
	if compatibility.Layout == nil {
		return nil, controller.StreamLayout{}, fmt.Errorf("DVD title streams cannot be joined: %+v", compatibility.Issue)
	}
	for index, probe := range probes[1:] {
		if !sameDVDLanguages(probes[0].Streams, probe.Streams) {
			return nil, controller.StreamLayout{}, fmt.Errorf("DVD title %d has different stream languages", index+2)
		}
	}
	return metadata, *compatibility.Layout, nil
}

func dvdPartChapters(probed []controller.ProbeChapter, durationMS int64) ([]mediajoin.Chapter, error) {
	if len(probed) == 0 {
		// FFmpeg omits the sole chapter. Mark it so the title is seekable after joining.
		return []mediajoin.Chapter{{EndMS: durationMS}}, nil
	}

	// The stager already checked the remux duration against the DVD title.
	// Clip authored intervals to that remux's playback span before shifting
	// them. Chapters outside the span refer to time with no playable media.
	chapters := make([]mediajoin.Chapter, 0, len(probed))
	var previousEnd int64
	for index, chapter := range probed {
		if chapter.StartTimeMS == nil || chapter.EndTimeMS == nil {
			return nil, fmt.Errorf("chapter %d is missing timing", index+1)
		}
		start, end := *chapter.StartTimeMS, *chapter.EndTimeMS
		if end <= start || index > 0 && start < previousEnd {
			return nil, fmt.Errorf("chapter %d spans %d–%d ms after previous end %d ms", index+1, start, end, previousEnd)
		}
		previousEnd = end
		start, end = max(start, 0), min(end, durationMS)
		if start < end {
			chapters = append(chapters, mediajoin.Chapter{StartMS: start, EndMS: end})
		}
	}
	if len(chapters) == 0 {
		return nil, fmt.Errorf("no DVD chapters overlap the %d ms playback span", durationMS)
	}
	return chapters, nil
}

func sameDVDLanguages(first, second []controller.ProbeStream) bool {
	if len(first) != len(second) {
		return false
	}
	language := func(stream controller.ProbeStream) string {
		for _, tag := range stream.Tags {
			if tag.Name == "language" {
				return tag.Value
			}
		}
		return ""
	}
	for index, stream := range first {
		if language(stream) != language(second[index]) {
			return false
		}
	}
	return true
}

func validateJoinedDVD(
	first dvdstage.Specification, metadata []mediajoin.PartMetadata, layout controller.StreamLayout,
	reference, output controller.ProbeEvidence,
) error {
	if !layout.MatchesMuxedOutput(output.Streams) || !sameDVDLanguages(reference.Streams, output.Streams) {
		return fmt.Errorf("joined DVD streams differ from the remuxed titles")
	}
	var offset int64
	chapterIndex := 0
	for _, part := range metadata {
		for _, chapter := range part.Chapters {
			if chapterIndex >= len(output.Chapters) {
				return fmt.Errorf("joined DVD is missing chapters")
			}
			actual := output.Chapters[chapterIndex]
			if actual.StartTimeMS == nil || actual.EndTimeMS == nil {
				return fmt.Errorf("joined DVD chapter %d is missing timing", chapterIndex+1)
			}
			start, end := offset+chapter.StartMS, offset+chapter.EndMS
			if !dvdChapterTimeMatches(*actual.StartTimeMS, start) || !dvdChapterTimeMatches(*actual.EndTimeMS, end) {
				return fmt.Errorf("joined DVD chapter %d spans %d–%d ms, expected %d–%d ms",
					chapterIndex+1, *actual.StartTimeMS, *actual.EndTimeMS, start, end)
			}
			chapterIndex++
		}
		offset += part.DurationMS
	}
	return remuxverification.ValidateDVDOutput(offset, chapterIndex, first.ExpectedTracks, output)
}

func dvdChapterTimeMatches(actual, expected int64) bool {
	// Matroska quantizes the chapter timestamps to milliseconds.
	return actual >= expected-2 && actual <= expected+2
}

func dvdOutputDirectory(specs []dvdstage.Specification) []string {
	var common []string
	for index, spec := range specs {
		directory := spec.Navigation.PathComponents[:len(spec.Navigation.PathComponents)-1]
		if len(directory) > 0 && strings.EqualFold(directory[len(directory)-1], "VIDEO_TS") {
			directory = directory[:len(directory)-1]
		}
		if index == 0 {
			common = directory
			continue
		}
		shared := 0
		for shared < min(len(directory), len(common)) && directory[shared] == common[shared] {
			shared++
		}
		common = common[:shared]
	}
	return common
}
