package workerclient

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/radarr-repair/internal/dvdvideo"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

var _ dvdvideo.Identifier = (*Client)(nil)

func (client *Client) IdentifyDVD(
	ctx context.Context, target dvdvideo.Target,
) ([]dvdvideo.Title, error) {
	if !client.configured() {
		return nil, fmt.Errorf("worker client is not configured")
	}
	rootID, components, err := client.resolve(target.NavigationPath)
	if err != nil {
		return nil, err
	}
	requestID := client.nextID()
	payload, err := workercontracts.EncodeDVDIdentifyRequest(workercontracts.DVDIdentifyRequestV1{
		ExpectedFingerprint: target.ExpectedFingerprint,
		Operation:           workercontracts.IdentifyDVDV1,
		PathComponents:      components,
		RequestID:           requestID, RootID: rootID,
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
	})
	if err != nil {
		return nil, fmt.Errorf("construct worker DVD request: %w", err)
	}
	data, err := client.post(ctx, "/v1/dvd/identify", payload, workercontracts.MaxDVDIdentifyResponseBytes)
	if err != nil {
		return nil, err
	}
	response, err := workercontracts.DecodeDVDIdentifyResponse(data)
	if err != nil || response.RequestID() != requestID {
		return nil, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if response.Failure != nil {
		return nil, &Failure{Kind: FailureRejected, Reason: workercontracts.Reason(response.Failure.Reason)}
	}
	if response.Success == nil {
		return nil, &Failure{Kind: FailureInvalidResponse}
	}
	titles := make([]dvdvideo.Title, 0, len(response.Success.Titles))
	for _, wire := range response.Success.Titles {
		tracks := make([]dvdvideo.Track, 0, len(wire.Tracks))
		for _, track := range wire.Tracks {
			language := ""
			if track.Language != nil {
				language = *track.Language
			}
			tracks = append(tracks, dvdvideo.Track{
				Kind: string(track.Kind), Codec: track.Codec, Language: language,
			})
		}
		titles = append(titles, dvdvideo.Title{
			Number: int(wire.Number), DurationMS: wire.DurationMS,
			Chapters: int(wire.ChapterCount), Angles: int(wire.AngleCount),
			TitleSet: int(wire.TitleSet), TitleInSet: int(wire.TitleInSet),
			Tracks: tracks,
		})
	}
	return titles, nil
}
