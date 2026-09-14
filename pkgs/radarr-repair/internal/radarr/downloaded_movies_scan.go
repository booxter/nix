package radarr

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"golift.io/starr"
)

type DownloadedMoviesScan struct {
	Path       string
	DownloadID string
}

type downloadedMoviesScanCommandRequest struct {
	Name             string                      `json:"name"`
	Path             string                      `json:"path"`
	DownloadClientID string                      `json:"downloadClientId"`
	ImportMode       controller.RadarrImportMode `json:"importMode"`
}

// RequestDownloadedMoviesScan asks Radarr to import one published joined file.
// Starr's command request supports only name and movieIds, so it cannot encode
// this command's path, downloadClientId, or importMode fields. Keep using Starr
// for authenticated HTTP while defining only the missing request shape here.
func (client *Client) RequestDownloadedMoviesScan(
	ctx context.Context,
	scan DownloadedMoviesScan,
) (Command, error) {
	if err := validateDownloadedMoviesScan(scan); err != nil {
		return Command{}, err
	}
	request := downloadedMoviesScanCommandRequest{
		Name:             downloadedMoviesScanCommandName,
		Path:             scan.Path,
		DownloadClientID: scan.DownloadID,
		ImportMode:       controller.RadarrImportModeCopy,
	}
	var body bytes.Buffer
	if err := json.NewEncoder(&body).Encode(request); err != nil {
		return Command{}, fmt.Errorf("encode Radarr downloaded-movies scan: %w", err)
	}

	var response commandResponse
	if err := client.api.PostInto(
		ctx,
		starr.Request{URI: commandPath, Body: &body},
		&response,
	); err != nil {
		return Command{}, normalizeRequestError("request Radarr downloaded-movies scan", err)
	}
	return mapCommand(response, 0, downloadedMoviesScanCommandName)
}

func (client *Client) ReadDownloadedMoviesScanCommand(
	ctx context.Context,
	commandID int64,
) (Command, error) {
	return client.readCommand(ctx, commandID, downloadedMoviesScanCommandName)
}

func validateDownloadedMoviesScan(scan DownloadedMoviesScan) error {
	if !validHistoryPath(scan.Path) {
		return fmt.Errorf("Radarr downloaded-movies scan path is invalid")
	}
	if scan.DownloadID == "" || strings.TrimSpace(scan.DownloadID) != scan.DownloadID ||
		strings.ContainsRune(scan.DownloadID, '\x00') {
		return fmt.Errorf("Radarr download ID is invalid")
	}
	return nil
}
