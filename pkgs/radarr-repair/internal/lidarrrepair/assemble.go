package lidarrrepair

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/lidarr"
	"github.com/booxter/nix-config/radarr-repair/lidarrcontracts"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/materialize"
)

type PathResolver interface {
	ResolvePublishedPath(string, []string) (string, error)
}

func Assemble(
	observedAt time.Time,
	queue lidarr.QueueRecord,
	album lidarr.Album,
	tracks []lidarr.Track,
	materialized materialize.Success,
	manualImports []lidarr.ManualImport,
	resolver PathResolver,
) (lidarrcontracts.Case, []ImportBinding, error) {
	if queue.AlbumID == nil || queue.ArtistID == nil || album.ID != *queue.AlbumID ||
		album.ArtistID != *queue.ArtistID || len(materialized.Artifacts) == 0 || resolver == nil {
		return lidarrcontracts.Case{}, nil, fmt.Errorf("Lidarr repair evidence is incomplete")
	}
	importsByPath := make(map[string]lidarr.ManualImport, len(manualImports))
	for _, item := range manualImports {
		importsByPath[item.Path] = item
	}

	artifacts := make([]lidarrcontracts.Artifact, 0, len(materialized.Artifacts))
	assessments := make([]lidarrcontracts.Assessment, 0, len(materialized.Artifacts))
	bindings := make([]ImportBinding, 0, len(materialized.Artifacts))
	artifactIDs := make([]string, 0, len(materialized.Artifacts))
	for _, artifact := range materialized.Artifacts {
		absolutePath, err := resolver.ResolvePublishedPath(
			materialized.RootID, artifact.PathComponents,
		)
		if err != nil {
			return lidarrcontracts.Case{}, nil, fmt.Errorf("resolve materialized artifact: %w", err)
		}
		item, found := importsByPath[absolutePath]
		if !found {
			return lidarrcontracts.Case{}, nil, fmt.Errorf(
				"Lidarr did not assess materialized artifact %q", artifact.ArtifactID,
			)
		}
		artifacts = append(artifacts, contractArtifact(artifact))
		assessments = append(assessments, contractAssessment(artifact.ArtifactID, item))
		bindings = append(bindings, bindingFromImport(artifact.ArtifactID, item))
		artifactIDs = append(artifactIDs, artifact.ArtifactID)
	}

	releases := make([]lidarrcontracts.Release, len(album.Releases))
	releaseIDs := make([]int64, len(album.Releases))
	for index, release := range album.Releases {
		releases[index] = lidarrcontracts.Release{
			ReleaseID: release.ID, Title: release.Title, Disambiguation: release.Disambiguation,
			Format: release.Format, TrackCount: release.TrackCount,
			MediumCount: release.MediumCount, Monitored: release.Monitored,
		}
		releaseIDs[index] = release.ID
	}
	contractTracks := make([]lidarrcontracts.Track, len(tracks))
	trackIDs := make([]int64, len(tracks))
	for index, track := range tracks {
		contractTracks[index] = lidarrcontracts.Track{
			TrackID: track.ID, Number: track.TrackNumber,
			AbsoluteNumber: track.AbsoluteTrackNumber, MediumNumber: track.MediumNumber,
			Title: track.Title, DurationMS: track.DurationMS, HasFile: track.HasFile,
		}
		trackIDs[index] = track.ID
	}
	if len(releaseIDs) == 0 || len(trackIDs) == 0 {
		return lidarrcontracts.Case{}, nil, fmt.Errorf("Lidarr album has no release or track candidates")
	}

	repairCase := lidarrcontracts.Case{
		SchemaVersion: lidarrcontracts.SchemaVersion, ObservedAt: observedAt.UTC(),
		Queue: lidarrcontracts.Queue{
			QueueID: queue.ID, Title: queue.Title, DownloadRef: opaqueDownloadRef(queue.DownloadID),
			Messages: queueMessages(queue),
		},
		Album: lidarrcontracts.Album{
			AlbumID: album.ID, ArtistID: album.ArtistID, Artist: album.ArtistName,
			Title: album.Title, Monitored: album.Monitored,
		},
		Releases: releases, Tracks: contractTracks, Artifacts: artifacts,
		Assessments: assessments,
		Capabilities: []lidarrcontracts.Capability{{
			Action:       string(lidarrcontracts.ActionImportTrackSet),
			CapabilityID: "capability:import_track_set", AlbumID: album.ID,
			ArtifactIDs: artifactIDs, ReleaseIDs: releaseIDs, TrackIDs: trackIDs,
		}},
	}
	caseID, err := lidarrcontracts.CalculateCaseID(repairCase)
	if err != nil {
		return lidarrcontracts.Case{}, nil, err
	}
	repairCase.CaseID = caseID
	if _, err := lidarrcontracts.EncodeCase(repairCase); err != nil {
		return lidarrcontracts.Case{}, nil, err
	}
	return repairCase, bindings, nil
}

func contractArtifact(artifact materialize.Artifact) lidarrcontracts.Artifact {
	evidence := artifact.Evidence
	tags := append(contractTags(evidence.Format.Tags), streamTags(evidence.Streams)...)
	return lidarrcontracts.Artifact{
		ArtifactID: artifact.ArtifactID, RelativePath: artifact.RelativePath,
		Fingerprint: artifact.Fingerprint, SizeBytes: artifact.SizeBytes,
		DurationMS: effectiveDuration(evidence), Formats: append([]string(nil), evidence.Format.Names...),
		Tags: tags, Streams: contractStreams(evidence.Streams),
	}
}

func contractAssessment(artifactID string, item lidarr.ManualImport) lidarrcontracts.Assessment {
	result := lidarrcontracts.Assessment{
		ArtifactID: artifactID, TrackIDs: append([]int64(nil), item.TrackIDs...),
		TagTrackNumbers: []int{}, Rejections: make([]string, len(item.Rejections)),
	}
	if item.AlbumID > 0 {
		result.AlbumID = pointer(item.AlbumID)
	}
	if item.AlbumReleaseID > 0 {
		result.ReleaseID = pointer(item.AlbumReleaseID)
	}
	if item.AudioTags != nil {
		result.TagTitle = optionalText(item.AudioTags.Title)
		result.TagArtist = optionalText(item.AudioTags.Artist)
		result.TagAlbum = optionalText(item.AudioTags.Album)
		result.TagTrackNumbers = append([]int(nil), item.AudioTags.TrackNumbers...)
	}
	for index, rejection := range item.Rejections {
		result.Rejections[index] = rejection.Type + ": " + rejection.Reason
	}
	return result
}

func contractTags(tags []workercontracts.TagElement) []lidarrcontracts.Tag {
	result := make([]lidarrcontracts.Tag, 0, len(tags))
	for _, tag := range tags {
		name := strings.TrimSpace(string(tag.Name))
		value := strings.TrimSpace(tag.Value)
		if name != "" && value != "" {
			result = append(result, lidarrcontracts.Tag{Name: name, Value: value})
		}
	}
	return result
}

func streamTags(streams []workercontracts.StreamElement) []lidarrcontracts.Tag {
	var result []lidarrcontracts.Tag
	for _, stream := range streams {
		result = append(result, contractTags(stream.Tags)...)
	}
	return result
}

func contractStreams(streams []workercontracts.StreamElement) []lidarrcontracts.Stream {
	result := make([]lidarrcontracts.Stream, len(streams))
	for index, stream := range streams {
		kind := "other"
		if stream.Kind != nil {
			kind = string(*stream.Kind)
		}
		result[index] = lidarrcontracts.Stream{
			Kind: kind, Codec: stream.CodecName, SampleRateHz: stream.SampleRateHz,
			Channels: stream.Channels, BitRateBPS: stream.BitRateBps,
		}
	}
	return result
}

func effectiveDuration(evidence workercontracts.Evidence) *int64 {
	if evidence.Format.DurationMS != nil && *evidence.Format.DurationMS > 0 {
		return evidence.Format.DurationMS
	}
	var longest int64
	for _, stream := range evidence.Streams {
		if stream.DurationMS != nil && *stream.DurationMS > longest {
			longest = *stream.DurationMS
		}
	}
	if longest == 0 {
		return nil
	}
	return &longest
}

func queueMessages(queue lidarr.QueueRecord) []string {
	result := make([]string, 0)
	for _, status := range queue.StatusMessages {
		if title := strings.TrimSpace(status.Title); title != "" {
			result = append(result, title)
		}
		for _, message := range status.Messages {
			if message = strings.TrimSpace(message); message != "" {
				result = append(result, message)
			}
		}
	}
	if message := strings.TrimSpace(queue.ErrorMessage); message != "" {
		result = append(result, message)
	}
	sort.Strings(result)
	return result
}

func opaqueDownloadRef(downloadID string) string {
	return stableID("download", downloadID)
}

func workspaceID(queueID int64, fingerprint string) string {
	return stableID("workspace", fmt.Sprintf("%d\x00%s", queueID, fingerprint))
}

func stableID(kind, value string) string {
	digest := sha256.Sum256([]byte(value))
	return kind + ":" + hex.EncodeToString(digest[:])
}

func pointer[T any](value T) *T { return &value }

func optionalText(value string) *string {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	return &value
}

func workspaceRoot(resolver PathResolver, materialized materialize.Success) (string, error) {
	root, err := resolver.ResolvePublishedPath(
		materialized.RootID, materialized.WorkspaceComponents,
	)
	if err != nil {
		return "", err
	}
	return filepath.Clean(root), nil
}
