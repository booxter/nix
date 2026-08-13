package reconcile

import (
	"context"
	"testing"

	"github.com/booxter/nix-config/seerr-reconcile/internal/seerrapi"
)

type fakeAPI struct {
	main         seerrapi.MainSettings
	mainUpdates  int
	libraries    []seerrapi.JellyfinLibrary
	librarySyncs int
}

func (api *fakeAPI) Main(context.Context) (seerrapi.MainSettings, error) { return api.main, nil }
func (api *fakeAPI) UpdateMain(_ context.Context, settings seerrapi.MainSettings) error {
	api.main = settings
	api.mainUpdates++
	return nil
}
func (api *fakeAPI) Jellyfin(context.Context) (seerrapi.JellyfinSettings, error) {
	return seerrapi.JellyfinSettings{Libraries: &api.libraries}, nil
}
func (api *fakeAPI) UpdateJellyfin(_ context.Context, settings seerrapi.JellyfinSettings) (seerrapi.JellyfinSettings, error) {
	return settings, nil
}
func (api *fakeAPI) SyncJellyfinLibraries(_ context.Context, _ bool, enabled []string) ([]seerrapi.JellyfinLibrary, error) {
	selected := make(map[string]bool, len(enabled))
	for _, id := range enabled {
		selected[id] = true
	}
	for index := range api.libraries {
		api.libraries[index].Enabled = selected[api.libraries[index].Id]
	}
	api.librarySyncs++
	return api.libraries, nil
}
func (*fakeAPI) Metadata(context.Context) (seerrapi.MetadataSettings, error) {
	panic("unexpected Metadata call")
}
func (*fakeAPI) UpdateMetadata(context.Context, seerrapi.MetadataSettings) error {
	panic("unexpected UpdateMetadata call")
}
func (*fakeAPI) Radarr(context.Context) ([]seerrapi.RadarrSettings, error) {
	panic("unexpected Radarr call")
}
func (*fakeAPI) TestRadarr(context.Context, seerrapi.PostSettingsRadarrTestJSONBody) ([]seerrapi.ServiceProfile, error) {
	panic("unexpected TestRadarr call")
}
func (*fakeAPI) CreateRadarr(context.Context, seerrapi.RadarrSettings) error {
	panic("unexpected CreateRadarr call")
}
func (*fakeAPI) UpdateRadarr(context.Context, int, seerrapi.RadarrSettings) error {
	panic("unexpected UpdateRadarr call")
}
func (*fakeAPI) Sonarr(context.Context) ([]seerrapi.SonarrSettings, error) {
	panic("unexpected Sonarr call")
}
func (*fakeAPI) TestSonarr(context.Context, seerrapi.PostSettingsSonarrTestJSONBody) ([]seerrapi.ServiceProfile, error) {
	panic("unexpected TestSonarr call")
}
func (*fakeAPI) CreateSonarr(context.Context, seerrapi.SonarrSettings) error {
	panic("unexpected CreateSonarr call")
}
func (*fakeAPI) UpdateSonarr(context.Context, int, seerrapi.SonarrSettings) error {
	panic("unexpected UpdateSonarr call")
}
func (*fakeAPI) Telegram(context.Context) (seerrapi.TelegramSettings, error) {
	panic("unexpected Telegram call")
}
func (*fakeAPI) UpdateTelegram(context.Context, seerrapi.TelegramSettings) error {
	panic("unexpected UpdateTelegram call")
}

func TestReconcileMainIsIdempotent(t *testing.T) {
	api := &fakeAPI{main: seerrapi.MainSettings{
		DefaultPermissions:     floatPointer(8352),
		EnableSpecialEpisodes:  boolPointer(true),
		LocalLogin:             boolPointer(true),
		MediaServerLogin:       boolPointer(true),
		MediaServerType:        floatPointer(2),
		PartialRequestsEnabled: boolPointer(true),
	}}
	desired := MainConfig{
		DefaultPermissions: []string{"request", "auto-approve", "advanced-request"},
		LocalLogin:         true, MediaServerLogin: true, PartialRequests: true, SpecialEpisodes: true,
	}
	changed, err := reconcileMain(context.Background(), api, desired)
	if err != nil {
		t.Fatal(err)
	}
	if changed || api.mainUpdates != 0 {
		t.Fatal("matching settings must not be updated")
	}
	desired.LocalLogin = false
	changed, err = reconcileMain(context.Background(), api, desired)
	if err != nil {
		t.Fatal(err)
	}
	if !changed || api.mainUpdates != 1 || api.main.LocalLogin == nil || *api.main.LocalLogin {
		t.Fatal("changed local login policy was not reconciled")
	}
}

func TestReconcileJellyfinLibrariesUsesNames(t *testing.T) {
	api := &fakeAPI{libraries: []seerrapi.JellyfinLibrary{
		{Id: "opaque-a", Name: "Cinema", Enabled: true},
		{Id: "opaque-b", Name: "Television", Enabled: false},
	}}
	changed, err := reconcileJellyfinLibraries(
		context.Background(), api,
		seerrapi.JellyfinSettings{Libraries: &api.libraries},
		[]string{"Television"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !changed || api.librarySyncs != 1 || api.libraries[0].Enabled || !api.libraries[1].Enabled {
		t.Fatal("library selection was not reconciled by display name")
	}
}

func TestGeneratedMasks(t *testing.T) {
	permissions, err := permissionMask([]string{"request", "auto-approve", "advanced-request"})
	if err != nil || permissions != 8352 {
		t.Fatalf("unexpected permission mask %d: %v", permissions, err)
	}
	events, err := notificationMask([]string{"request-pending", "issue-reopened"})
	if err != nil || events != 2050 {
		t.Fatalf("unexpected notification mask %d: %v", events, err)
	}
}

func TestEnsureClaimedRejectsUnmanagedInstances(t *testing.T) {
	err := ensureClaimed(
		[]seerrapi.RadarrSettings{{Name: "unmanaged"}},
		[]ServarrConfig{{DisplayName: "declared"}},
		func(value seerrapi.RadarrSettings) string { return value.Name },
	)
	if err == nil {
		t.Fatal("unmanaged existing integration must be rejected")
	}
}
