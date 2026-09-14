package radarr

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"golift.io/starr"
	starrRadarr "golift.io/starr/radarr"
)

const (
	commandPath                     = starrRadarr.APIver + "/command"
	manualImportCommandName         = "ManualImport"
	downloadedMoviesScanCommandName = "DownloadedMoviesScan"
)

type CommandStatus string

const (
	CommandQueued    CommandStatus = "queued"
	CommandStarted   CommandStatus = "started"
	CommandCompleted CommandStatus = "completed"
	CommandFailed    CommandStatus = "failed"
	CommandAborted   CommandStatus = "aborted"
	CommandCancelled CommandStatus = "cancelled"
	CommandOrphaned  CommandStatus = "orphaned"
)

type CommandResult string

const (
	CommandResultUnknown      CommandResult = "unknown"
	CommandResultSuccessful   CommandResult = "successful"
	CommandResultUnsuccessful CommandResult = "unsuccessful"
)

type Command struct {
	ID        int64
	Name      string
	Message   string
	Exception string
	Status    CommandStatus
	Result    CommandResult
}

type commandResponse struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	Message   string `json:"message"`
	Exception string `json:"exception"`
	Status    string `json:"status"`
	Result    string `json:"result"`
}

type manualImportCommandRequest struct {
	Name       string                      `json:"name"`
	Files      []manualImportCommandFile   `json:"files"`
	ImportMode controller.RadarrImportMode `json:"importMode"`
}

type manualImportCommandFile struct {
	Path         string                 `json:"path"`
	FolderName   string                 `json:"folderName"`
	Quality      manualImportQuality    `json:"quality"`
	Languages    []manualImportLanguage `json:"languages"`
	ReleaseGroup string                 `json:"releaseGroup"`
	IndexerFlags int64                  `json:"indexerFlags"`
	DownloadID   string                 `json:"downloadId"`
	MovieID      int64                  `json:"movieId"`
}

type manualImportQuality struct {
	Quality  manualImportBaseQuality      `json:"quality"`
	Revision *manualImportQualityRevision `json:"revision,omitempty"`
}

type manualImportBaseQuality struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	Source     string `json:"source"`
	Resolution int    `json:"resolution"`
	Modifier   string `json:"modifier"`
}

type manualImportQualityRevision struct {
	Version  int64 `json:"version"`
	Real     int64 `json:"real"`
	IsRepack bool  `json:"isRepack"`
}

type manualImportLanguage struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// RequestManualImport submits the one file already authorized by local policy.
// Starr's command request only models name and movie IDs, so it cannot encode
// Radarr's files or importMode fields. Keep using Starr for authenticated HTTP,
// but model this request here until Starr gains typed ManualImport support; this
// gap would be better fixed upstream than expanded into more local API models.
func (client *Client) RequestManualImport(
	ctx context.Context,
	authorized decisionpolicy.AuthorizedManualImport,
) (Command, error) {
	if err := validateAuthorizedManualImport(authorized); err != nil {
		return Command{}, err
	}

	request := manualImportCommandRequest{
		Name:       manualImportCommandName,
		Files:      []manualImportCommandFile{mapManualImportCommandFile(authorized.File)},
		ImportMode: authorized.ImportMode,
	}
	var body bytes.Buffer
	if err := json.NewEncoder(&body).Encode(request); err != nil {
		return Command{}, fmt.Errorf("encode Radarr manual-import command: %w", err)
	}

	var response commandResponse
	if err := client.api.PostInto(ctx, starr.Request{URI: commandPath, Body: &body}, &response); err != nil {
		return Command{}, normalizeRequestError("request Radarr manual import", err)
	}
	return mapCommand(response, 0, manualImportCommandName)
}

func (client *Client) ReadManualImportCommand(
	ctx context.Context,
	commandID int64,
) (Command, error) {
	return client.readCommand(ctx, commandID, manualImportCommandName)
}

func (client *Client) readCommand(
	ctx context.Context,
	commandID int64,
	expectedName string,
) (Command, error) {
	if commandID <= 0 {
		return Command{}, fmt.Errorf("Radarr command ID must be positive")
	}

	var response commandResponse
	path := commandPath + "/" + strconv.FormatInt(commandID, 10)
	if err := client.api.GetInto(ctx, starr.Request{URI: path}, &response); err != nil {
		return Command{}, normalizeRequestError("read Radarr command", err)
	}
	return mapCommand(response, commandID, expectedName)
}

func validateAuthorizedManualImport(authorized decisionpolicy.AuthorizedManualImport) error {
	binding := controller.RadarrManualImportBinding{
		FileID:              authorized.FileID,
		ExpectedFingerprint: authorized.ExpectedFingerprint,
		ImportMode:          authorized.ImportMode,
		File:                authorized.File,
	}
	if authorized.CaseID == "" || authorized.CapabilityID == "" || !binding.Complete() {
		return fmt.Errorf("authorized Radarr manual import is incomplete")
	}
	return nil
}

func mapManualImportCommandFile(file controller.RadarrManualImportCommandFile) manualImportCommandFile {
	languages := make([]manualImportLanguage, len(file.Languages))
	for index, language := range file.Languages {
		languages[index] = manualImportLanguage{ID: language.ID, Name: language.Name}
	}
	quality := manualImportQuality{
		Quality: manualImportBaseQuality{
			ID: file.Quality.Quality.ID, Name: file.Quality.Quality.Name,
			Source: file.Quality.Quality.Source, Resolution: file.Quality.Quality.Resolution,
			Modifier: file.Quality.Quality.Modifier,
		},
	}
	if file.Quality.Revision != nil {
		quality.Revision = &manualImportQualityRevision{
			Version: file.Quality.Revision.Version, Real: file.Quality.Revision.Real,
			IsRepack: file.Quality.Revision.IsRepack,
		}
	}
	return manualImportCommandFile{
		Path: file.Path, FolderName: file.FolderName, Quality: quality,
		Languages: languages, ReleaseGroup: file.ReleaseGroup,
		IndexerFlags: file.IndexerFlags, DownloadID: file.DownloadID, MovieID: file.MovieID,
	}
}

func mapCommand(response commandResponse, expectedID int64, expectedName string) (Command, error) {
	if response.ID <= 0 {
		return Command{}, fmt.Errorf("Radarr command response has invalid ID %d", response.ID)
	}
	if expectedID != 0 && response.ID != expectedID {
		return Command{}, fmt.Errorf(
			"Radarr returned command ID %d for requested ID %d",
			response.ID,
			expectedID,
		)
	}
	if response.Name != expectedName {
		return Command{}, fmt.Errorf(
			"Radarr returned command %q instead of %q",
			response.Name,
			expectedName,
		)
	}
	if response.Status == "" {
		return Command{}, fmt.Errorf("Radarr command response has no status")
	}
	return Command{
		ID: response.ID, Name: response.Name, Message: response.Message,
		Exception: response.Exception, Status: CommandStatus(response.Status),
		Result: CommandResult(response.Result),
	}, nil
}
