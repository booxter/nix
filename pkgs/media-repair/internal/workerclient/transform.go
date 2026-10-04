package workerclient

import (
	"context"
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
)

func (client *Client) Transform(ctx context.Context, request mediaoperation.Transform) (mediaoperation.Output, error) {
	data, err := json.Marshal(request)
	if err != nil {
		return mediaoperation.Output{}, err
	}
	data, err = client.postWithTimeout(ctx, "transform", data, 8<<20, client.stageTimeout)
	if err != nil {
		return mediaoperation.Output{}, err
	}
	var output mediaoperation.Output
	err = json.Unmarshal(data, &output)
	return output, err
}
