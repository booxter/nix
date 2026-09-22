package dvdstage

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

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/remuxverification"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/dvdremux"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"github.com/gowebpki/jcs"
)

const artifactDomain = "radarr-repair-worker-dvd-artifact-v1\x00"

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
	Navigation           Source           `json:"navigation"`
	Sources              []Source         `json:"sources"`
	TitleNumber          int              `json:"title_number"`
	ExpectedDurationMS   int64            `json:"expected_duration_ms"`
	ExpectedChapterCount int              `json:"expected_chapter_count"`
	ExpectedTracks       []dvdvideo.Track `json:"expected_tracks"`
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
	identifier dvdvideo.Identifier
	remuxer    dvdremux.Remuxer
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
	files Files, artifacts mediafile.RecoverableStagedArtifacts,
	identifier dvdvideo.Identifier, remuxer dvdremux.Remuxer, prober Prober,
) (*Executor, error) {
	if files == nil || artifacts == nil || identifier == nil || remuxer == nil || prober == nil {
		return nil, fmt.Errorf("DVD stage dependencies are required")
	}
	return &Executor{files: files, artifacts: artifacts, identifier: identifier,
		remuxer: remuxer, prober: prober}, nil
}

func ArtifactID(spec Specification) (string, error) {
	if err := validateSpecification(spec); err != nil {
		return "", err
	}
	data, err := json.Marshal(spec)
	if err != nil {
		return "", fmt.Errorf("encode DVD artifact identity: %w", err)
	}
	canonical, err := jcs.Transform(data)
	if err != nil {
		return "", fmt.Errorf("canonicalize DVD artifact identity: %w", err)
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(artifactDomain))
	_, _ = digest.Write(canonical)
	return "artifact:" + hex.EncodeToString(digest.Sum(nil)), nil
}

func (executor *Executor) StageOrRecover(ctx context.Context, spec Specification) (Result, error) {
	if executor == nil || ctx == nil {
		return Result{}, fmt.Errorf("DVD stage executor is not configured")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	artifactID, err := ArtifactID(spec)
	if err != nil {
		return Result{}, err
	}
	inputs, directory, err := executor.openAndIdentify(ctx, spec)
	if err != nil {
		return Result{}, err
	}
	defer closeFiles(inputs)
	completed, err := mediafile.PrepareStage(executor.artifacts, spec.RootID,
		artifactID, workercontracts.OutputContainerMKV)
	if err != nil {
		return Result{}, err
	}
	if completed != nil {
		return executor.recover(ctx, spec, artifactID, inputs, completed)
	}
	return executor.stage(ctx, spec, artifactID, directory, inputs)
}

func (executor *Executor) stage(
	ctx context.Context, spec Specification, artifactID, directory string,
	inputs []*os.File,
) (result Result, returnedErr error) {
	var sourceBytes int64
	for _, source := range spec.Sources {
		sourceBytes += source.SizeBytes
	}
	artifact, err := executor.artifacts.CreateStaged(spec.RootID, artifactID,
		workercontracts.OutputContainerMKV, sourceBytes)
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
	size, remuxErr := executor.remuxer.RemuxDVD(ctx, directory, spec.TitleNumber, artifact.File())
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
	if err := remuxverification.ValidateDVDOutput(spec.ExpectedDurationMS,
		spec.ExpectedChapterCount, spec.ExpectedTracks, evidence); err != nil {
		return Result{}, err
	}
	fingerprint, snapshotSize, err := artifact.Snapshot()
	if err != nil || size <= 0 || size != snapshotSize {
		return Result{}, fmt.Errorf("DVD remux output changed after probing: %w", err)
	}
	if err := artifact.Retain(); err != nil {
		return Result{}, err
	}
	retained = true
	return Result{ArtifactID: artifactID, Fingerprint: fingerprint,
		SizeBytes: snapshotSize, Evidence: evidence}, nil
}

func (executor *Executor) recover(
	ctx context.Context, spec Specification, artifactID string,
	inputs []*os.File, artifact mediafile.CompletedArtifact,
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
	if err := remuxverification.ValidateDVDOutput(spec.ExpectedDurationMS,
		spec.ExpectedChapterCount, spec.ExpectedTracks, evidence); err != nil {
		removed, removeErr := executor.artifacts.RemoveCompleted(spec.RootID,
			artifactID, workercontracts.OutputContainerMKV, before)
		if removeErr != nil || !removed {
			return Result{}, errors.Join(err, removeErr,
				fmt.Errorf("invalid staged DVD artifact was not removed"))
		}
		return Result{}, err
	}
	after, sizeAfter, err := artifact.Snapshot()
	if err != nil || before != after || sizeBefore != sizeAfter || sizeAfter <= 0 {
		return Result{}, fmt.Errorf("completed DVD artifact changed during probe: %w", err)
	}
	if err := executor.verifyInputs(spec, inputs); err != nil {
		return Result{}, err
	}
	return Result{ArtifactID: artifactID, Fingerprint: after,
		SizeBytes: sizeAfter, Evidence: evidence}, nil
}

func (executor *Executor) openAndIdentify(
	ctx context.Context, spec Specification,
) ([]*os.File, string, error) {
	opened := make([]*os.File, 0, len(spec.Sources))
	directory := ""
	seen := make(map[string]bool, len(spec.Sources))
	for _, source := range spec.Sources {
		media, err := executor.files.Open(spec.RootID, source.PathComponents,
			source.ExpectedFingerprint)
		if err != nil {
			closeFiles(opened)
			return nil, "", err
		}
		opened = append(opened, media)
		info, err := media.Stat()
		if err != nil || info.Size() != source.SizeBytes {
			closeFiles(opened)
			return nil, "", fmt.Errorf("DVD source size changed")
		}
		path, err := executor.files.AbsolutePath(spec.RootID, source.PathComponents)
		if err != nil {
			closeFiles(opened)
			return nil, "", err
		}
		if directory == "" {
			directory = filepath.Dir(path)
		}
		if filepath.Dir(path) != directory || seen[filepath.Base(path)] {
			closeFiles(opened)
			return nil, "", fmt.Errorf("DVD sources do not form one VIDEO_TS directory")
		}
		seen[filepath.Base(path)] = true
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != len(seen) {
		closeFiles(opened)
		return nil, "", fmt.Errorf("DVD source directory changed")
	}
	for _, entry := range entries {
		info, infoErr := entry.Info()
		if infoErr != nil || !seen[entry.Name()] || !info.Mode().IsRegular() {
			closeFiles(opened)
			return nil, "", fmt.Errorf("DVD source directory contains an unbound file")
		}
	}
	titles, err := executor.identifier.IdentifyDVD(ctx, dvdvideo.Target{
		NavigationPath:      filepath.Join(directory, "VIDEO_TS.IFO"),
		ExpectedFingerprint: spec.Navigation.ExpectedFingerprint,
	})
	if err == nil {
		matched := false
		for _, title := range titles {
			if title.Number == spec.TitleNumber && title.DurationMS == spec.ExpectedDurationMS &&
				title.Chapters == spec.ExpectedChapterCount && title.Angles == 1 &&
				reflect.DeepEqual(title.Tracks, spec.ExpectedTracks) {
				matched = true
			}
		}
		if !matched {
			err = fmt.Errorf("DVD title metadata changed")
		}
	}
	if err == nil {
		err = executor.verifyInputs(spec, opened)
	}
	if err != nil {
		closeFiles(opened)
		return nil, "", err
	}
	return opened, directory, nil
}

func (executor *Executor) verifyInputs(spec Specification, opened []*os.File) error {
	if len(opened) != len(spec.Sources) {
		return fmt.Errorf("DVD source count changed")
	}
	for index, source := range spec.Sources {
		if err := executor.files.Verify(opened[index], source.ExpectedFingerprint); err != nil {
			return err
		}
		fresh, err := executor.files.Open(spec.RootID, source.PathComponents,
			source.ExpectedFingerprint)
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
		spec.RootID == "" || spec.TitleNumber < 1 || spec.TitleNumber > 128 ||
		spec.ExpectedDurationMS <= 0 || spec.ExpectedDurationMS > 7*24*60*60*1_000 ||
		spec.ExpectedChapterCount <= 0 || spec.ExpectedChapterCount > 4096 ||
		len(spec.Sources) < 3 || len(spec.Sources) > 1024 ||
		len(spec.ExpectedTracks) < 2 || len(spec.ExpectedTracks) > 32 {
		return fmt.Errorf("invalid DVD remux specification")
	}
	parts := spec.Navigation.PathComponents
	if len(parts) < 2 || parts[len(parts)-2] != "VIDEO_TS" ||
		parts[len(parts)-1] != "VIDEO_TS.IFO" || !validSource(spec.Navigation) {
		return fmt.Errorf("invalid DVD navigation source")
	}
	directory := parts[:len(parts)-1]
	var sourceBytes int64
	foundNavigation := false
	lastName := ""
	for _, source := range spec.Sources {
		path := source.PathComponents
		if len(path) != len(parts) || !slices.Equal(path[:len(directory)], directory) ||
			!validSource(source) || !dvdvideo.ValidFileName(path[len(path)-1]) ||
			path[len(path)-1] <= lastName || source.SizeBytes > math.MaxInt64-sourceBytes {
			return fmt.Errorf("invalid DVD source list")
		}
		lastName = path[len(path)-1]
		sourceBytes += source.SizeBytes
		if slices.Equal(source.PathComponents, spec.Navigation.PathComponents) {
			foundNavigation = source.ExpectedFingerprint == spec.Navigation.ExpectedFingerprint &&
				source.SizeBytes == spec.Navigation.SizeBytes
		}
	}
	if !foundNavigation {
		return fmt.Errorf("DVD navigation file is not among the sources")
	}
	hasVideo, hasAudio := false, false
	for _, track := range spec.ExpectedTracks {
		if track.Codec == "" ||
			(track.Kind != "video" && track.Kind != "audio" && track.Kind != "subtitles") {
			return fmt.Errorf("invalid DVD track expectation")
		}
		hasVideo = hasVideo || track.Kind == "video"
		hasAudio = hasAudio || track.Kind == "audio"
	}
	if !hasVideo || !hasAudio {
		return fmt.Errorf("DVD track expectation lacks video or audio")
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
