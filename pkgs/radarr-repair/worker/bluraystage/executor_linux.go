package bluraystage

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
	"github.com/booxter/nix-config/radarr-repair/internal/remuxverification"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaremux"
	"github.com/gowebpki/jcs"
)

const artifactDomain = "radarr-repair-worker-bluray-artifact-v1\x00"

type Source struct {
	PathComponents      []string `json:"path_components"`
	ExpectedFingerprint string   `json:"expected_fingerprint"`
	SizeBytes           int64    `json:"size_bytes"`
}

type Specification struct {
	ExecutionID          string           `json:"execution_id"`
	CaseID               string           `json:"case_id"`
	CapabilityID         string           `json:"capability_id"`
	RootID               string           `json:"root_id"`
	Playlist             Source           `json:"playlist"`
	Clips                []Source         `json:"clips"`
	ExpectedDurationMS   int64            `json:"expected_duration_ms"`
	ExpectedChapterCount int              `json:"expected_chapter_count"`
	ExpectedTracks       []mkvmerge.Track `json:"expected_tracks"`
}

type Files interface {
	Open(string, []string, string) (*os.File, error)
	Verify(*os.File, string) error
	AbsolutePath(string, []string) (string, error)
}

type Prober interface {
	ProbeFile(context.Context, *os.File) (controller.ProbeEvidence, error)
}

type Executor struct {
	files      Files
	artifacts  mediafile.RecoverableStagedArtifacts
	identifier mkvmerge.Identifier
	remuxer    mediaremux.Remuxer
	prober     Prober
}

type Result struct {
	ArtifactID  string
	Fingerprint string
	SizeBytes   int64
	Evidence    controller.ProbeEvidence
}

var (
	_ Files                                = (*mediafile.RootSet)(nil)
	_ mediafile.RecoverableStagedArtifacts = (*mediafile.RootSet)(nil)
	_ Prober                               = (*ffprobe.Runner)(nil)
)

func NewExecutor(
	files Files,
	artifacts mediafile.RecoverableStagedArtifacts,
	identifier mkvmerge.Identifier,
	remuxer mediaremux.Remuxer,
	prober Prober,
) (*Executor, error) {
	if files == nil || artifacts == nil || identifier == nil ||
		remuxer == nil || prober == nil {
		return nil, fmt.Errorf("Blu-ray stage dependencies are required")
	}
	return &Executor{
		files: files, artifacts: artifacts, identifier: identifier,
		remuxer: remuxer, prober: prober,
	}, nil
}

func ArtifactID(spec Specification) (string, error) {
	if err := validateSpecification(spec); err != nil {
		return "", err
	}
	data, err := json.Marshal(spec)
	if err != nil {
		return "", fmt.Errorf("encode Blu-ray artifact identity: %w", err)
	}
	canonical, err := jcs.Transform(data)
	if err != nil {
		return "", fmt.Errorf("canonicalize Blu-ray artifact identity: %w", err)
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(artifactDomain))
	_, _ = digest.Write(canonical)
	return "artifact:" + hex.EncodeToString(digest.Sum(nil)), nil
}

func (executor *Executor) StageOrRecover(
	ctx context.Context,
	spec Specification,
) (Result, error) {
	if executor == nil || ctx == nil {
		return Result{}, fmt.Errorf("Blu-ray stage executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	artifactID, err := ArtifactID(spec)
	if err != nil {
		return Result{}, err
	}
	inputs, playlistPath, err := executor.openAndIdentify(ctx, spec)
	if err != nil {
		return Result{}, err
	}
	defer closeFiles(inputs)

	completed, err := mediafile.PrepareStage(
		executor.artifacts,
		spec.RootID, artifactID, workercontracts.OutputContainerMKV,
	)
	if err != nil {
		return Result{}, err
	}
	if completed != nil {
		return executor.recover(ctx, spec, artifactID, inputs, completed)
	}
	return executor.stage(ctx, spec, artifactID, playlistPath, inputs)
}

func (executor *Executor) stage(
	ctx context.Context,
	spec Specification,
	artifactID string,
	playlistPath string,
	inputs []*os.File,
) (result Result, returnedErr error) {
	sourceBytes := int64(0)
	for _, clip := range spec.Clips {
		sourceBytes += clip.SizeBytes
	}
	artifact, err := executor.artifacts.CreateStaged(
		spec.RootID, artifactID, workercontracts.OutputContainerMKV, sourceBytes,
	)
	if err != nil {
		return Result{}, err
	}
	retained := false
	defer func() {
		if !retained {
			if err := artifact.Discard(); err != nil {
				result = Result{}
				returnedErr = errors.Join(returnedErr, err)
			}
		}
	}()
	size, remuxErr := executor.remuxer.Remux(ctx, playlistPath, artifact.File())
	if err := executor.verifyInputs(spec, inputs); err != nil {
		return Result{}, err
	}
	if remuxErr != nil {
		return Result{}, remuxErr
	}
	evidence, err := executor.prober.ProbeFile(ctx, artifact.File())
	if err != nil {
		return Result{}, err
	}
	if err := remuxverification.ValidateOutput(
		spec.ExpectedDurationMS, spec.ExpectedChapterCount, spec.ExpectedTracks, evidence,
	); err != nil {
		return Result{}, err
	}
	fingerprint, snapshotSize, err := artifact.Snapshot()
	if err != nil {
		return Result{}, err
	}
	if size <= 0 || size != snapshotSize {
		return Result{}, fmt.Errorf("Blu-ray remux output size changed")
	}
	if err := artifact.Retain(); err != nil {
		return Result{}, err
	}
	retained = true
	return Result{
		ArtifactID: artifactID, Fingerprint: fingerprint,
		SizeBytes: snapshotSize, Evidence: evidence,
	}, nil
}

func (executor *Executor) recover(
	ctx context.Context,
	spec Specification,
	artifactID string,
	inputs []*os.File,
	artifact mediafile.CompletedArtifact,
) (Result, error) {
	defer artifact.Close()
	before, sizeBefore, err := artifact.Snapshot()
	if err != nil {
		return Result{}, err
	}
	evidence, err := executor.prober.ProbeFile(ctx, artifact.File())
	if err != nil {
		return Result{}, err
	}
	if err := remuxverification.ValidateOutput(
		spec.ExpectedDurationMS, spec.ExpectedChapterCount, spec.ExpectedTracks, evidence,
	); err != nil {
		removed, removeErr := executor.artifacts.RemoveCompleted(
			spec.RootID, artifactID, workercontracts.OutputContainerMKV, before,
		)
		if removeErr != nil || !removed {
			return Result{}, errors.Join(err, removeErr, fmt.Errorf("invalid staged artifact was not removed"))
		}
		return Result{}, err
	}
	after, sizeAfter, err := artifact.Snapshot()
	if err != nil {
		return Result{}, err
	}
	if before != after || sizeBefore != sizeAfter || sizeAfter <= 0 {
		return Result{}, fmt.Errorf("completed Blu-ray artifact changed during probe")
	}
	if err := executor.verifyInputs(spec, inputs); err != nil {
		return Result{}, err
	}
	return Result{
		ArtifactID: artifactID, Fingerprint: after,
		SizeBytes: sizeAfter, Evidence: evidence,
	}, nil
}

func (executor *Executor) openAndIdentify(
	ctx context.Context,
	spec Specification,
) ([]*os.File, string, error) {
	sources := append([]Source{spec.Playlist}, spec.Clips...)
	opened := make([]*os.File, 0, len(sources))
	paths := make([]string, 0, len(sources))
	for _, source := range sources {
		media, err := executor.files.Open(
			spec.RootID, source.PathComponents, source.ExpectedFingerprint,
		)
		if err != nil {
			closeFiles(opened)
			return nil, "", err
		}
		opened = append(opened, media)
		info, err := media.Stat()
		if err != nil || info.Size() != source.SizeBytes {
			closeFiles(opened)
			return nil, "", fmt.Errorf("Blu-ray source size changed")
		}
		path, err := executor.files.AbsolutePath(spec.RootID, source.PathComponents)
		if err != nil {
			closeFiles(opened)
			return nil, "", err
		}
		paths = append(paths, path)
	}
	details, err := executor.identifier.Identify(ctx, mkvmerge.Target{
		Path: paths[0], ExpectedFingerprint: spec.Playlist.ExpectedFingerprint,
	})
	if err == nil && (details.DurationMS != spec.ExpectedDurationMS ||
		details.Chapters != spec.ExpectedChapterCount ||
		!reflect.DeepEqual(details.Tracks, spec.ExpectedTracks) ||
		!slices.Equal(details.ClipPaths, paths[1:])) {
		err = fmt.Errorf("Blu-ray playlist metadata changed")
	}
	if err == nil {
		err = executor.verifyInputs(spec, opened)
	}
	if err != nil {
		closeFiles(opened)
		return nil, "", err
	}
	return opened, paths[0], nil
}

func (executor *Executor) verifyInputs(spec Specification, opened []*os.File) error {
	sources := append([]Source{spec.Playlist}, spec.Clips...)
	if len(sources) != len(opened) {
		return fmt.Errorf("Blu-ray input count changed")
	}
	for index, source := range sources {
		if err := executor.files.Verify(opened[index], source.ExpectedFingerprint); err != nil {
			return err
		}
		fresh, err := executor.files.Open(
			spec.RootID, source.PathComponents, source.ExpectedFingerprint,
		)
		if err != nil {
			return err
		}
		if err := fresh.Close(); err != nil {
			return err
		}
	}
	return nil
}

func validateSpecification(spec Specification) error {
	if spec.ExecutionID == "" || spec.CaseID == "" || spec.CapabilityID == "" ||
		spec.RootID == "" || spec.ExpectedDurationMS <= 0 ||
		spec.ExpectedDurationMS > 7*24*60*60*1_000 ||
		spec.ExpectedChapterCount < 0 || spec.ExpectedChapterCount > 4096 ||
		len(spec.Clips) == 0 || len(spec.Clips) > 1024 ||
		len(spec.ExpectedTracks) == 0 || len(spec.ExpectedTracks) > 32 {
		return fmt.Errorf("invalid Blu-ray remux specification")
	}
	parts := spec.Playlist.PathComponents
	if len(parts) < 3 || parts[len(parts)-3] != "BDMV" ||
		parts[len(parts)-2] != "PLAYLIST" ||
		!mkvmerge.NumberedPlaylist(parts[len(parts)-1]) ||
		!validSource(spec.Playlist) {
		return fmt.Errorf("invalid Blu-ray playlist input")
	}
	disc := parts[:len(parts)-3]
	var sourceBytes int64
	for _, clip := range spec.Clips {
		path := clip.PathComponents
		if len(path) != len(parts) || !slices.Equal(path[:len(disc)], disc) ||
			path[len(path)-3] != "BDMV" || path[len(path)-2] != "STREAM" ||
			!mkvmerge.NumberedClip(path[len(path)-1]) || !validSource(clip) ||
			clip.SizeBytes > math.MaxInt64-sourceBytes {
			return fmt.Errorf("invalid Blu-ray clip input")
		}
		sourceBytes += clip.SizeBytes
	}
	hasVideo := false
	for _, track := range spec.ExpectedTracks {
		if track.Codec == "" ||
			(track.Kind != "video" && track.Kind != "audio" && track.Kind != "subtitles") {
			return fmt.Errorf("invalid Blu-ray track expectation")
		}
		hasVideo = hasVideo || track.Kind == "video"
	}
	if !hasVideo {
		return fmt.Errorf("Blu-ray track expectation has no video")
	}
	return nil
}

func validSource(source Source) bool {
	if source.ExpectedFingerprint == "" || source.SizeBytes <= 0 {
		return false
	}
	for _, part := range source.PathComponents {
		if part == "" || part == "." || part == ".." ||
			strings.ContainsAny(part, "/\x00") || filepath.Base(part) != part {
			return false
		}
	}
	return true
}

func closeFiles(files []*os.File) {
	for _, file := range files {
		_ = file.Close()
	}
}
