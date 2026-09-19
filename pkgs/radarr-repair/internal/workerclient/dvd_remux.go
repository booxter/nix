package workerclient

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

const dvdRemuxPath = "/v1/dvd/remux"
const dvdPublishPath = "/v1/dvd/publish"

type DVDRemuxExchange struct {
	Request  workercontracts.DVDRemuxRequestV1
	Response workercontracts.DVDRemuxResponseV1
}

func (client *Client) StageDVDRemux(
	ctx context.Context, executionID string, authorized decisionpolicy.AuthorizedDVD,
	absolutePaths map[controller.FileID]string,
) (DVDRemuxExchange, error) {
	if !client.configured() {
		return DVDRemuxExchange{}, fmt.Errorf("worker client is not configured")
	}
	all := append([]decisionpolicy.AuthorizedRemuxFile{authorized.Navigation}, authorized.Sources...)
	paths := make([]string, 0, len(all))
	for _, source := range all {
		path, found := absolutePaths[source.FileID]
		if !found {
			return DVDRemuxExchange{}, fmt.Errorf("authorized DVD input %q has no path", source.FileID)
		}
		paths = append(paths, path)
	}
	rootID, components, err := client.resolveTogether(paths)
	if err != nil {
		return DVDRemuxExchange{}, err
	}
	sources := make([]workercontracts.DVDRemuxSourceV1, 0, len(authorized.Sources))
	for index, source := range authorized.Sources {
		sources = append(sources, dvdSource(source, components[index+1]))
	}
	tracks := make([]workercontracts.DVDRemuxTrackV1, 0, len(authorized.ExpectedTracks))
	for _, track := range authorized.ExpectedTracks {
		tracks = append(tracks, workercontracts.DVDRemuxTrackV1{
			Kind: workercontracts.TrackKind(track.Kind), Codec: track.Codec,
			Language: track.Language,
		})
	}
	request := workercontracts.DVDRemuxRequestV1{
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Operation:     workercontracts.StageDVDRemuxV1,
		RequestID:     client.nextID(), ExecutionID: executionID,
		CaseID: authorized.CaseID, CapabilityID: authorized.CapabilityID,
		RootID:     rootID,
		Navigation: dvdSource(authorized.Navigation, components[0]), Sources: sources,
		TitleNumber:          int64(authorized.TitleNumber),
		ExpectedDurationMS:   authorized.ExpectedDurationMS,
		ExpectedChapterCount: int64(authorized.ExpectedChapters),
		ExpectedTracks:       tracks,
	}
	payload, err := workercontracts.EncodeDVDRemuxRequest(request)
	if err != nil {
		return DVDRemuxExchange{}, fmt.Errorf("construct worker DVD remux request: %w", err)
	}
	data, err := client.postWithTimeout(ctx, dvdRemuxPath, payload,
		workercontracts.MaxDVDRemuxResponseBytes, client.stageTimeout)
	if err != nil {
		return DVDRemuxExchange{}, err
	}
	response, err := workercontracts.DecodeDVDRemuxResponse(data)
	if err != nil || response.RequestID() != request.RequestID {
		return DVDRemuxExchange{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	return DVDRemuxExchange{Request: request, Response: response}, nil
}

func dvdSource(
	source decisionpolicy.AuthorizedRemuxFile, components []string,
) workercontracts.DVDRemuxSourceV1 {
	return workercontracts.DVDRemuxSourceV1{
		PathComponents:      append([]string(nil), components...),
		ExpectedFingerprint: source.Fingerprint.Fingerprint(),
		SizeBytes:           source.Fingerprint.SizeBytes,
	}
}

func (client *Client) PublishDVDRemux(
	ctx context.Context, stageRequest workercontracts.DVDRemuxRequestV1, artifact Artifact,
) (workercontracts.DVDPublishResponseV1, error) {
	if !client.configured() {
		return workercontracts.DVDPublishResponseV1{}, fmt.Errorf("worker client is not configured")
	}
	request := workercontracts.DVDPublishRequestV1{
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
		Operation:     workercontracts.PublishDVDRemuxV1,
		RequestID:     client.nextID(), StageRequest: stageRequest,
		ArtifactID: artifact.ID, ArtifactFingerprint: artifact.Fingerprint,
	}
	payload, err := workercontracts.EncodeDVDPublishRequest(request)
	if err != nil {
		return workercontracts.DVDPublishResponseV1{}, fmt.Errorf("construct worker DVD publish request: %w", err)
	}
	data, err := client.post(ctx, dvdPublishPath, payload,
		workercontracts.MaxDVDPublishResponseBytes)
	if err != nil {
		return workercontracts.DVDPublishResponseV1{}, err
	}
	response, err := workercontracts.DecodeDVDPublishResponse(data)
	if err != nil || response.RequestID() != request.RequestID {
		return workercontracts.DVDPublishResponseV1{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	return response, nil
}
