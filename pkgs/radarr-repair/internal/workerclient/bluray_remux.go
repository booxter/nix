package workerclient

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const blurayRemuxPath = "/v1/bluray/remux"
const blurayPublishPath = "/v1/bluray/publish"

type BlurayRemuxExchange struct {
	Request  workercontracts.BlurayRemuxRequestV1
	Response workercontracts.BlurayRemuxResponseV1
}

func (client *Client) StageBlurayRemux(
	ctx context.Context,
	executionID string,
	authorized decisionpolicy.AuthorizedRemux,
	absolutePaths map[controller.FileID]string,
) (BlurayRemuxExchange, error) {
	if !client.configured() {
		return BlurayRemuxExchange{}, fmt.Errorf("worker client is not configured")
	}
	sources := append([]decisionpolicy.AuthorizedRemuxFile{authorized.Playlist}, authorized.Clips...)
	paths := make([]string, 0, len(sources))
	for _, source := range sources {
		path, found := absolutePaths[source.FileID]
		if !found {
			return BlurayRemuxExchange{}, fmt.Errorf("authorized Blu-ray input %q has no path", source.FileID)
		}
		paths = append(paths, path)
	}
	rootID, components, err := client.resolveTogether(paths)
	if err != nil {
		return BlurayRemuxExchange{}, err
	}
	clips := make([]workercontracts.BlurayRemuxSourceV1, 0, len(authorized.Clips))
	for index, clip := range authorized.Clips {
		clips = append(clips, remuxSource(clip, components[index+1]))
	}
	tracks := make([]workercontracts.BlurayRemuxTrackV1, 0, len(authorized.ExpectedTracks))
	for _, track := range authorized.ExpectedTracks {
		tracks = append(tracks, workercontracts.BlurayRemuxTrackV1{
			Kind:  workercontracts.TrackKind(track.Kind),
			Codec: track.Codec, Language: track.Language,
		})
	}
	request := workercontracts.BlurayRemuxRequestV1{
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Operation:     workercontracts.StageBlurayRemuxV1,
		RequestID:     client.nextID(), ExecutionID: executionID,
		CaseID: authorized.CaseID, CapabilityID: authorized.CapabilityID,
		RootID:               rootID,
		Playlist:             remuxSource(authorized.Playlist, components[0]),
		Clips:                clips,
		ExpectedDurationMS:   authorized.ExpectedDurationMS,
		ExpectedChapterCount: authorized.ExpectedChapters,
		ExpectedTracks:       tracks,
	}
	payload, err := workercontracts.EncodeBlurayRemuxRequest(request)
	if err != nil {
		return BlurayRemuxExchange{}, fmt.Errorf("construct worker Blu-ray remux request: %w", err)
	}
	data, err := client.postWithTimeout(
		ctx, blurayRemuxPath, payload, workercontracts.MaxBlurayRemuxResponseBytes,
		client.stageTimeout,
	)
	if err != nil {
		return BlurayRemuxExchange{}, err
	}
	response, err := workercontracts.DecodeBlurayRemuxResponse(data)
	if err != nil || response.RequestID() != request.RequestID {
		return BlurayRemuxExchange{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	return BlurayRemuxExchange{Request: request, Response: response}, nil
}

func remuxSource(
	source decisionpolicy.AuthorizedRemuxFile,
	components []string,
) workercontracts.BlurayRemuxSourceV1 {
	return workercontracts.BlurayRemuxSourceV1{
		PathComponents:      append([]string(nil), components...),
		ExpectedFingerprint: source.Fingerprint.Fingerprint(),
		SizeBytes:           source.Fingerprint.SizeBytes,
	}
}

func (client *Client) PublishBlurayRemux(
	ctx context.Context,
	stageRequest workercontracts.BlurayRemuxRequestV1,
	artifact Artifact,
) (workercontracts.BlurayPublishResponseV1, error) {
	if !client.configured() {
		return workercontracts.BlurayPublishResponseV1{}, fmt.Errorf("worker client is not configured")
	}
	request := workercontracts.BlurayPublishRequestV1{
		SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
		Operation:           workercontracts.PublishBlurayRemuxV1,
		RequestID:           client.nextID(),
		StageRequest:        stageRequest,
		ArtifactID:          artifact.ID,
		ArtifactFingerprint: artifact.Fingerprint,
	}
	payload, err := workercontracts.EncodeBlurayPublishRequest(request)
	if err != nil {
		return workercontracts.BlurayPublishResponseV1{}, fmt.Errorf(
			"construct worker Blu-ray publish request: %w", err,
		)
	}
	data, err := client.post(
		ctx, blurayPublishPath, payload, workercontracts.MaxBlurayPublishResponseBytes,
	)
	if err != nil {
		return workercontracts.BlurayPublishResponseV1{}, err
	}
	response, err := workercontracts.DecodeBlurayPublishResponse(data)
	if err != nil || response.RequestID() != request.RequestID {
		return workercontracts.BlurayPublishResponseV1{}, &Failure{
			Kind: FailureInvalidResponse, cause: err,
		}
	}
	return response, nil
}
