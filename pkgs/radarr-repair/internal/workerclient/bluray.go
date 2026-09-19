package workerclient

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

var _ mkvmerge.Identifier = (*Client)(nil)

func (client *Client) Identify(
	ctx context.Context,
	target mkvmerge.Target,
) (mkvmerge.Playlist, error) {
	if !client.configured() {
		return mkvmerge.Playlist{}, fmt.Errorf("worker client is not configured")
	}
	rootID, components, err := client.resolve(target.Path)
	if err != nil {
		return mkvmerge.Playlist{}, err
	}
	requestID := client.nextID()
	payload, err := workercontracts.EncodeBlurayIdentifyRequest(
		workercontracts.BlurayIdentifyRequestV1{
			ExpectedFingerprint: target.ExpectedFingerprint,
			Operation:           workercontracts.IdentifyBlurayV1,
			PathComponents:      components,
			RequestID:           requestID,
			RootID:              rootID,
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
		},
	)
	if err != nil {
		return mkvmerge.Playlist{}, fmt.Errorf("construct worker Blu-ray request: %w", err)
	}
	data, err := client.post(
		ctx, "/v1/bluray/identify", payload,
		workercontracts.MaxBlurayIdentifyResponseBytes,
	)
	if err != nil {
		return mkvmerge.Playlist{}, err
	}
	response, err := workercontracts.DecodeBlurayIdentifyResponse(data)
	if err != nil || response.RequestID() != requestID {
		return mkvmerge.Playlist{}, &Failure{Kind: FailureInvalidResponse, cause: err}
	}
	if response.Failure != nil {
		return mkvmerge.Playlist{}, &Failure{
			Kind: FailureRejected, Reason: workercontracts.Reason(response.Failure.Reason),
		}
	}
	if response.Success == nil {
		return mkvmerge.Playlist{}, &Failure{Kind: FailureInvalidResponse}
	}
	streamDir := filepath.Join(filepath.Dir(filepath.Dir(target.Path)), "STREAM")
	playlist := mkvmerge.Playlist{
		DurationMS: response.Success.DurationMS,
		Chapters:   int(response.Success.ChapterCount),
		ClipPaths:  make([]string, 0, len(response.Success.ClipNames)),
		Tracks:     make([]mkvmerge.Track, 0, len(response.Success.Tracks)),
	}
	for _, name := range response.Success.ClipNames {
		playlist.ClipPaths = append(playlist.ClipPaths, filepath.Join(streamDir, name))
	}
	for _, track := range response.Success.Tracks {
		language := ""
		if track.Language != nil {
			language = *track.Language
		}
		playlist.Tracks = append(playlist.Tracks, mkvmerge.Track{
			Kind: string(track.Kind), Codec: track.Codec, Language: language,
		})
	}
	return playlist, nil
}
