package reconcile

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/booxter/nix-config/seerr-reconcile/internal/seerrapi"
)

type API interface {
	Main(context.Context) (seerrapi.MainSettings, error)
	UpdateMain(context.Context, seerrapi.MainSettings) error
	Jellyfin(context.Context) (seerrapi.JellyfinSettings, error)
	UpdateJellyfin(context.Context, seerrapi.JellyfinSettings) (seerrapi.JellyfinSettings, error)
	SyncJellyfinLibraries(context.Context, bool, []string) ([]seerrapi.JellyfinLibrary, error)
	Metadata(context.Context) (seerrapi.MetadataSettings, error)
	UpdateMetadata(context.Context, seerrapi.MetadataSettings) error
	Radarr(context.Context) ([]seerrapi.RadarrSettings, error)
	TestRadarr(context.Context, seerrapi.PostSettingsRadarrTestJSONBody) ([]seerrapi.ServiceProfile, error)
	CreateRadarr(context.Context, seerrapi.RadarrSettings) error
	UpdateRadarr(context.Context, int, seerrapi.RadarrSettings) error
	Sonarr(context.Context) ([]seerrapi.SonarrSettings, error)
	TestSonarr(context.Context, seerrapi.PostSettingsSonarrTestJSONBody) ([]seerrapi.ServiceProfile, error)
	CreateSonarr(context.Context, seerrapi.SonarrSettings) error
	UpdateSonarr(context.Context, int, seerrapi.SonarrSettings) error
	Telegram(context.Context) (seerrapi.TelegramSettings, error)
	UpdateTelegram(context.Context, seerrapi.TelegramSettings) error
}

type HTTPAPI struct {
	client *seerrapi.ClientWithResponses
}

func NewHTTPAPI(baseURL, apiKey string, client *http.Client) (*HTTPAPI, error) {
	requestEditor := func(_ context.Context, request *http.Request) error {
		request.Header.Set("X-Api-Key", apiKey)
		return nil
	}
	generated, err := seerrapi.NewClientWithResponses(
		strings.TrimRight(baseURL, "/")+"/api/v1",
		seerrapi.WithHTTPClient(client),
		seerrapi.WithRequestEditorFn(requestEditor),
	)
	if err != nil {
		return nil, fmt.Errorf("create Seerr API client: %w", err)
	}
	return &HTTPAPI{client: generated}, nil
}

func responseError(operation string, status int, body []byte) error {
	message := strings.TrimSpace(string(body))
	if len(message) > 300 {
		message = message[:300]
	}
	return fmt.Errorf("%s returned HTTP %d: %s", operation, status, message)
}

func (api *HTTPAPI) Main(ctx context.Context) (seerrapi.MainSettings, error) {
	response, err := api.client.GetSettingsMainWithResponse(ctx)
	if err != nil {
		return seerrapi.MainSettings{}, err
	}
	if response.JSON200 == nil {
		return seerrapi.MainSettings{}, responseError("get main settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) UpdateMain(ctx context.Context, settings seerrapi.MainSettings) error {
	response, err := api.client.PostSettingsMainWithResponse(ctx, settings)
	if err != nil {
		return err
	}
	if response.JSON200 == nil {
		return responseError("update main settings", response.StatusCode(), response.Body)
	}
	return nil
}

func (api *HTTPAPI) Jellyfin(ctx context.Context) (seerrapi.JellyfinSettings, error) {
	response, err := api.client.GetSettingsJellyfinWithResponse(ctx)
	if err != nil {
		return seerrapi.JellyfinSettings{}, err
	}
	if response.JSON200 == nil {
		return seerrapi.JellyfinSettings{}, responseError("get Jellyfin settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) UpdateJellyfin(ctx context.Context, settings seerrapi.JellyfinSettings) (seerrapi.JellyfinSettings, error) {
	response, err := api.client.PostSettingsJellyfinWithResponse(ctx, settings)
	if err != nil {
		return seerrapi.JellyfinSettings{}, err
	}
	if response.JSON200 == nil {
		return seerrapi.JellyfinSettings{}, responseError("update Jellyfin settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) SyncJellyfinLibraries(ctx context.Context, sync bool, enabled []string) ([]seerrapi.JellyfinLibrary, error) {
	syncValue := ""
	if sync {
		syncValue = "true"
	}
	enableValue := strings.Join(enabled, ",")
	response, err := api.client.GetSettingsJellyfinLibraryWithResponse(
		ctx,
		&seerrapi.GetSettingsJellyfinLibraryParams{Sync: &syncValue, Enable: &enableValue},
	)
	if err != nil {
		return nil, err
	}
	if response.JSON200 == nil {
		return nil, responseError("sync Jellyfin libraries", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) Metadata(ctx context.Context) (seerrapi.MetadataSettings, error) {
	response, err := api.client.GetSettingsMetadatasWithResponse(ctx)
	if err != nil {
		return seerrapi.MetadataSettings{}, err
	}
	if response.JSON200 == nil {
		return seerrapi.MetadataSettings{}, responseError("get metadata settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) UpdateMetadata(ctx context.Context, settings seerrapi.MetadataSettings) error {
	response, err := api.client.PutSettingsMetadatasWithResponse(ctx, settings)
	if err != nil {
		return err
	}
	if response.JSON200 == nil {
		return responseError("update metadata settings", response.StatusCode(), response.Body)
	}
	return nil
}

func (api *HTTPAPI) Radarr(ctx context.Context) ([]seerrapi.RadarrSettings, error) {
	response, err := api.client.GetSettingsRadarrWithResponse(ctx)
	if err != nil {
		return nil, err
	}
	if response.JSON200 == nil {
		return nil, responseError("get Radarr settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) TestRadarr(ctx context.Context, connection seerrapi.PostSettingsRadarrTestJSONBody) ([]seerrapi.ServiceProfile, error) {
	response, err := api.client.PostSettingsRadarrTestWithResponse(
		ctx,
		seerrapi.PostSettingsRadarrTestJSONRequestBody(connection),
	)
	if err != nil {
		return nil, err
	}
	if response.JSON200 == nil || response.JSON200.Profiles == nil {
		return nil, responseError("test Radarr settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200.Profiles, nil
}

func (api *HTTPAPI) CreateRadarr(ctx context.Context, settings seerrapi.RadarrSettings) error {
	response, err := api.client.PostSettingsRadarrWithResponse(ctx, settings)
	if err != nil {
		return err
	}
	if response.JSON201 == nil {
		return responseError("create Radarr settings", response.StatusCode(), response.Body)
	}
	return nil
}

func (api *HTTPAPI) UpdateRadarr(ctx context.Context, id int, settings seerrapi.RadarrSettings) error {
	response, err := api.client.PutSettingsRadarrRadarrIdWithResponse(ctx, id, settings)
	if err != nil {
		return err
	}
	if response.JSON200 == nil {
		return responseError("update Radarr settings", response.StatusCode(), response.Body)
	}
	return nil
}

func (api *HTTPAPI) Sonarr(ctx context.Context) ([]seerrapi.SonarrSettings, error) {
	response, err := api.client.GetSettingsSonarrWithResponse(ctx)
	if err != nil {
		return nil, err
	}
	if response.JSON200 == nil {
		return nil, responseError("get Sonarr settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) TestSonarr(ctx context.Context, connection seerrapi.PostSettingsSonarrTestJSONBody) ([]seerrapi.ServiceProfile, error) {
	response, err := api.client.PostSettingsSonarrTestWithResponse(
		ctx,
		seerrapi.PostSettingsSonarrTestJSONRequestBody(connection),
	)
	if err != nil {
		return nil, err
	}
	if response.JSON200 == nil || response.JSON200.Profiles == nil {
		return nil, responseError("test Sonarr settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200.Profiles, nil
}

func (api *HTTPAPI) CreateSonarr(ctx context.Context, settings seerrapi.SonarrSettings) error {
	response, err := api.client.PostSettingsSonarrWithResponse(ctx, settings)
	if err != nil {
		return err
	}
	if response.JSON201 == nil {
		return responseError("create Sonarr settings", response.StatusCode(), response.Body)
	}
	return nil
}

func (api *HTTPAPI) UpdateSonarr(ctx context.Context, id int, settings seerrapi.SonarrSettings) error {
	response, err := api.client.PutSettingsSonarrSonarrIdWithResponse(ctx, id, settings)
	if err != nil {
		return err
	}
	if response.JSON200 == nil {
		return responseError("update Sonarr settings", response.StatusCode(), response.Body)
	}
	return nil
}

func (api *HTTPAPI) Telegram(ctx context.Context) (seerrapi.TelegramSettings, error) {
	response, err := api.client.GetSettingsNotificationsTelegramWithResponse(ctx)
	if err != nil {
		return seerrapi.TelegramSettings{}, err
	}
	if response.JSON200 == nil {
		return seerrapi.TelegramSettings{}, responseError("get Telegram settings", response.StatusCode(), response.Body)
	}
	return *response.JSON200, nil
}

func (api *HTTPAPI) UpdateTelegram(ctx context.Context, settings seerrapi.TelegramSettings) error {
	response, err := api.client.PostSettingsNotificationsTelegramWithResponse(ctx, settings)
	if err != nil {
		return err
	}
	if response.JSON200 == nil {
		return responseError("update Telegram settings", response.StatusCode(), response.Body)
	}
	return nil
}
