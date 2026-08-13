package reconcile

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"reflect"
	"slices"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/seerr-reconcile/internal/seerrapi"
)

type Result struct {
	Changed []string
}

func Run(ctx context.Context, api API, credentials CredentialReader, config Config) (Result, error) {
	result := Result{}
	steps := []struct {
		name string
		run  func(context.Context) (bool, error)
	}{
		{"main settings", func(ctx context.Context) (bool, error) { return reconcileMain(ctx, api, config.Main) }},
		{"Jellyfin", func(ctx context.Context) (bool, error) {
			return reconcileJellyfin(ctx, api, credentials, config.Jellyfin)
		}},
		{"metadata", func(ctx context.Context) (bool, error) { return reconcileMetadata(ctx, api, config.Metadata) }},
		{"Radarr", func(ctx context.Context) (bool, error) { return reconcileRadarr(ctx, api, credentials, config.Radarr) }},
		{"Sonarr", func(ctx context.Context) (bool, error) { return reconcileSonarr(ctx, api, credentials, config.Sonarr) }},
	}
	if config.Telegram != nil {
		steps = append(steps, struct {
			name string
			run  func(context.Context) (bool, error)
		}{"Telegram", func(ctx context.Context) (bool, error) {
			return reconcileTelegram(ctx, api, credentials, *config.Telegram)
		}})
	}
	for _, step := range steps {
		changed, err := step.run(ctx)
		if err != nil {
			return result, fmt.Errorf("reconcile %s: %w", step.name, err)
		}
		if changed {
			result.Changed = append(result.Changed, step.name)
		}
	}
	return result, nil
}

func boolPointer(value bool) *bool       { return &value }
func floatPointer(value int) *float32    { converted := float32(value); return &converted }
func stringPointer(value string) *string { return &value }

func reconcileMain(ctx context.Context, api API, desired MainConfig) (bool, error) {
	current, err := api.Main(ctx)
	if err != nil {
		return false, err
	}
	updated := current
	permissions, err := permissionMask(desired.DefaultPermissions)
	if err != nil {
		return false, err
	}
	updated.DefaultPermissions = floatPointer(permissions)
	updated.EnableSpecialEpisodes = boolPointer(desired.SpecialEpisodes)
	updated.LocalLogin = boolPointer(desired.LocalLogin)
	updated.MediaServerLogin = boolPointer(desired.MediaServerLogin)
	updated.MediaServerType = floatPointer(2)
	updated.PartialRequestsEnabled = boolPointer(desired.PartialRequests)
	if reflect.DeepEqual(current, updated) {
		return false, nil
	}
	return true, api.UpdateMain(ctx, updated)
}

func reconcileJellyfin(ctx context.Context, api API, credentials CredentialReader, desired JellyfinConfig) (bool, error) {
	endpoint, err := url.Parse(desired.URL)
	if err != nil {
		return false, fmt.Errorf("parse Jellyfin URL: %w", err)
	}
	port, err := endpointPort(endpoint)
	if err != nil {
		return false, err
	}
	apiKey, err := credentials.ReadRaw(desired.APIKeyCredential)
	if err != nil {
		return false, err
	}
	current, err := api.Jellyfin(ctx)
	if err != nil {
		return false, err
	}
	updated := current
	updated.ApiKey = stringPointer(apiKey)
	updated.Ip = stringPointer(endpoint.Hostname())
	updated.Port = floatPointer(port)
	updated.UrlBase = stringPointer(strings.TrimSuffix(endpoint.EscapedPath(), "/"))
	updated.UseSsl = boolPointer(endpoint.Scheme == "https")
	changed := !jellyfinConnectionEqual(current, updated)
	if changed {
		updated, err = api.UpdateJellyfin(ctx, updated)
		if err != nil {
			return false, err
		}
	}
	libraryChanged, err := reconcileJellyfinLibraries(ctx, api, updated, desired.Libraries)
	return changed || libraryChanged, err
}

func jellyfinConnectionEqual(left, right seerrapi.JellyfinSettings) bool {
	return reflect.DeepEqual(left.ApiKey, right.ApiKey) &&
		reflect.DeepEqual(left.Ip, right.Ip) &&
		reflect.DeepEqual(left.Port, right.Port) &&
		reflect.DeepEqual(left.UrlBase, right.UrlBase) &&
		reflect.DeepEqual(left.UseSsl, right.UseSsl)
}

func reconcileJellyfinLibraries(ctx context.Context, api API, settings seerrapi.JellyfinSettings, desiredNames []string) (bool, error) {
	libraries := []seerrapi.JellyfinLibrary{}
	if settings.Libraries != nil {
		libraries = *settings.Libraries
	}
	missing := missingLibraryNames(libraries, desiredNames)
	if len(missing) > 0 {
		preserved := enabledLibraryIDs(libraries)
		var err error
		libraries, err = api.SyncJellyfinLibraries(ctx, true, preserved)
		if err != nil {
			return false, err
		}
		missing = missingLibraryNames(libraries, desiredNames)
	}
	if len(missing) > 0 {
		return false, fmt.Errorf("Jellyfin did not expose selected libraries: %s", strings.Join(missing, ", "))
	}
	desiredIDs := libraryIDsByName(libraries, desiredNames)
	currentIDs := enabledLibraryIDs(libraries)
	slices.Sort(desiredIDs)
	slices.Sort(currentIDs)
	if slices.Equal(currentIDs, desiredIDs) {
		return false, nil
	}
	_, err := api.SyncJellyfinLibraries(ctx, false, desiredIDs)
	return true, err
}

func missingLibraryNames(libraries []seerrapi.JellyfinLibrary, desired []string) []string {
	known := make(map[string]bool, len(libraries))
	for _, library := range libraries {
		known[library.Name] = true
	}
	missing := []string{}
	for _, name := range desired {
		if !known[name] {
			missing = append(missing, name)
		}
	}
	return missing
}

func enabledLibraryIDs(libraries []seerrapi.JellyfinLibrary) []string {
	ids := []string{}
	for _, library := range libraries {
		if library.Enabled {
			ids = append(ids, library.Id)
		}
	}
	return ids
}

func libraryIDsByName(libraries []seerrapi.JellyfinLibrary, names []string) []string {
	selected := make(map[string]bool, len(names))
	for _, name := range names {
		selected[name] = true
	}
	ids := []string{}
	for _, library := range libraries {
		if selected[library.Name] {
			ids = append(ids, library.Id)
		}
	}
	return ids
}

func reconcileMetadata(ctx context.Context, api API, desired MetadataConfig) (bool, error) {
	current, err := api.Metadata(ctx)
	if err != nil {
		return false, err
	}
	if current.Settings == nil {
		return false, fmt.Errorf("Seerr returned metadata settings without a settings object")
	}
	anime := seerrapi.MetadataSettingsSettingsAnime(desired.Anime)
	series := seerrapi.MetadataSettingsSettingsTv(desired.Series)
	if current.Settings.Anime != nil && *current.Settings.Anime == anime &&
		current.Settings.Tv != nil && *current.Settings.Tv == series {
		return false, nil
	}
	current.Settings.Anime = &anime
	current.Settings.Tv = &series
	return true, api.UpdateMetadata(ctx, current)
}

func endpointPort(endpoint *url.URL) (int, error) {
	if endpoint.Hostname() == "" {
		return 0, fmt.Errorf("endpoint URL has no hostname")
	}
	if endpoint.Port() != "" {
		port, err := strconv.Atoi(endpoint.Port())
		if err != nil {
			return 0, fmt.Errorf("parse endpoint port: %w", err)
		}
		return port, nil
	}
	switch endpoint.Scheme {
	case "http":
		return 80, nil
	case "https":
		return 443, nil
	default:
		return 0, fmt.Errorf("unsupported endpoint scheme %q", endpoint.Scheme)
	}
}

type servarrConnection struct {
	hostname string
	port     int
	useSSL   bool
	baseURL  *string
	apiKey   string
}

func resolveServarrConnection(credentials CredentialReader, desired ServarrConfig) (servarrConnection, error) {
	endpoint, err := url.Parse(desired.API)
	if err != nil {
		return servarrConnection{}, fmt.Errorf("parse API URL: %w", err)
	}
	port, err := endpointPort(endpoint)
	if err != nil {
		return servarrConnection{}, err
	}
	apiKey, err := credentials.Read(desired.Credential)
	if err != nil {
		return servarrConnection{}, err
	}
	var baseURL *string
	if path := strings.TrimSuffix(endpoint.EscapedPath(), "/"); path != "" {
		baseURL = &path
	}
	return servarrConnection{
		hostname: endpoint.Hostname(),
		port:     port,
		useSSL:   endpoint.Scheme == "https",
		baseURL:  baseURL,
		apiKey:   apiKey,
	}, nil
}

func profileID(profiles []seerrapi.ServiceProfile, name string) (int, error) {
	matches := []int{}
	for _, profile := range profiles {
		if profile.Name != nil && *profile.Name == name && profile.Id != nil {
			matches = append(matches, int(*profile.Id))
		}
	}
	if len(matches) != 1 {
		return 0, fmt.Errorf("profile %q matched %d profiles", name, len(matches))
	}
	return matches[0], nil
}

func ensureClaimed[T any](existing []T, desired []ServarrConfig, nameOf func(T) string) error {
	claimed := make(map[string]bool, len(desired))
	for _, instance := range desired {
		if claimed[instance.DisplayName] {
			return fmt.Errorf("duplicate desired instance name %q", instance.DisplayName)
		}
		claimed[instance.DisplayName] = true
	}
	for _, instance := range existing {
		if name := nameOf(instance); !claimed[name] {
			return fmt.Errorf("existing instance %q is not declared", name)
		}
	}
	return nil
}

func reconcileRadarr(ctx context.Context, api API, credentials CredentialReader, desired []ServarrConfig) (bool, error) {
	existing, err := api.Radarr(ctx)
	if err != nil {
		return false, err
	}
	if err := ensureClaimed(existing, desired, func(value seerrapi.RadarrSettings) string { return value.Name }); err != nil {
		return false, err
	}
	byName := make(map[string]seerrapi.RadarrSettings, len(existing))
	for _, value := range existing {
		if _, duplicate := byName[value.Name]; duplicate {
			return false, fmt.Errorf("multiple existing instances named %q", value.Name)
		}
		byName[value.Name] = value
	}
	changed := false
	for _, instance := range desired {
		connection, err := resolveServarrConnection(credentials, instance)
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		profiles, err := api.TestRadarr(ctx, seerrapi.PostSettingsRadarrTestJSONBody{
			ApiKey: connection.apiKey, BaseUrl: connection.baseURL, Hostname: connection.hostname,
			Port: float32(connection.port), UseSsl: connection.useSSL,
		})
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		profile, err := profileID(profiles, instance.Profile)
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		current, found := byName[instance.DisplayName]
		updated := current
		updated.ActiveDirectory = instance.LibraryPath
		updated.ActiveProfileId = float32(profile)
		updated.ActiveProfileName = instance.Profile
		updated.ApiKey = connection.apiKey
		updated.BaseUrl = connection.baseURL
		updated.Hostname = connection.hostname
		updated.Is4k = false
		updated.IsDefault = instance.Default
		updated.MinimumAvailability = instance.MinimumAvailability
		updated.Name = instance.DisplayName
		updated.Port = float32(connection.port)
		updated.PreventSearch = boolPointer(!instance.SearchRequests)
		updated.SyncEnabled = boolPointer(instance.AvailabilitySync)
		updated.TagRequests = boolPointer(instance.TagRequests)
		updated.UseSsl = connection.useSSL
		if found && reflect.DeepEqual(current, updated) {
			continue
		}
		if found {
			if current.Id == nil {
				return false, fmt.Errorf("existing instance %q has no ID", current.Name)
			}
			err = api.UpdateRadarr(ctx, int(*current.Id), updated)
		} else {
			err = api.CreateRadarr(ctx, updated)
		}
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		changed = true
	}
	return changed, nil
}

func reconcileSonarr(ctx context.Context, api API, credentials CredentialReader, desired []ServarrConfig) (bool, error) {
	existing, err := api.Sonarr(ctx)
	if err != nil {
		return false, err
	}
	if err := ensureClaimed(existing, desired, func(value seerrapi.SonarrSettings) string { return value.Name }); err != nil {
		return false, err
	}
	byName := make(map[string]seerrapi.SonarrSettings, len(existing))
	for _, value := range existing {
		if _, duplicate := byName[value.Name]; duplicate {
			return false, fmt.Errorf("multiple existing instances named %q", value.Name)
		}
		byName[value.Name] = value
	}
	changed := false
	for _, instance := range desired {
		connection, err := resolveServarrConnection(credentials, instance)
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		profiles, err := api.TestSonarr(ctx, seerrapi.PostSettingsSonarrTestJSONBody{
			ApiKey: connection.apiKey, BaseUrl: connection.baseURL, Hostname: connection.hostname,
			Port: float32(connection.port), UseSsl: connection.useSSL,
		})
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		profile, err := profileID(profiles, instance.Profile)
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		current, found := byName[instance.DisplayName]
		updated := current
		monitor := seerrapi.SonarrSettingsMonitorNewItems(instance.MonitorNewItems)
		seriesType := seerrapi.SonarrSettingsSeriesType("standard")
		updated.ActiveDirectory = instance.LibraryPath
		updated.ActiveProfileId = float32(profile)
		updated.ActiveProfileName = instance.Profile
		updated.ApiKey = connection.apiKey
		updated.BaseUrl = connection.baseURL
		updated.EnableSeasonFolders = instance.SeasonFolders
		updated.Hostname = connection.hostname
		updated.Is4k = false
		updated.IsDefault = instance.Default
		updated.MonitorNewItems = &monitor
		updated.Name = instance.DisplayName
		updated.Port = float32(connection.port)
		updated.PreventSearch = boolPointer(!instance.SearchRequests)
		updated.SeriesType = &seriesType
		updated.SyncEnabled = boolPointer(instance.AvailabilitySync)
		updated.TagRequests = boolPointer(instance.TagRequests)
		updated.UseSsl = connection.useSSL
		if found && reflect.DeepEqual(current, updated) {
			continue
		}
		if found {
			if current.Id == nil {
				return false, fmt.Errorf("existing instance %q has no ID", current.Name)
			}
			err = api.UpdateSonarr(ctx, int(*current.Id), updated)
		} else {
			err = api.CreateSonarr(ctx, updated)
		}
		if err != nil {
			return false, fmt.Errorf("%s: %w", instance.DisplayName, err)
		}
		changed = true
	}
	return changed, nil
}

type telegramPayload struct {
	EmbedPoster bool `json:"embedPoster"`
	Enabled     bool `json:"enabled"`
	Options     struct {
		BotAPI          string `json:"botAPI"`
		BotUsername     string `json:"botUsername"`
		ChatID          string `json:"chatId"`
		MessageThreadID string `json:"messageThreadId"`
		SendSilently    bool   `json:"sendSilently"`
	} `json:"options"`
	Types int `json:"types"`
}

func permissionMask(names []string) (int, error) {
	values := map[string]int{
		"request":          seerrapi.PermissionRequest,
		"auto-approve":     seerrapi.PermissionAutoApprove,
		"advanced-request": seerrapi.PermissionRequestAdvanced,
	}
	return selectedMask("permission", names, values)
}

func notificationMask(names []string) (int, error) {
	values := map[string]int{
		"request-pending":       seerrapi.NotificationMediaPending,
		"request-approved":      seerrapi.NotificationMediaApproved,
		"request-available":     seerrapi.NotificationMediaAvailable,
		"request-failed":        seerrapi.NotificationMediaFailed,
		"request-declined":      seerrapi.NotificationMediaDeclined,
		"request-auto-approved": seerrapi.NotificationMediaAutoApproved,
		"request-auto-created":  seerrapi.NotificationMediaAutoRequested,
		"issue-created":         seerrapi.NotificationIssueCreated,
		"issue-commented":       seerrapi.NotificationIssueComment,
		"issue-resolved":        seerrapi.NotificationIssueResolved,
		"issue-reopened":        seerrapi.NotificationIssueReopened,
	}
	return selectedMask("notification event", names, values)
}

func selectedMask(kind string, names []string, values map[string]int) (int, error) {
	total := 0
	seen := make(map[string]bool, len(names))
	for _, name := range names {
		value, ok := values[name]
		if !ok {
			return 0, fmt.Errorf("unknown %s %q", kind, name)
		}
		if seen[name] {
			return 0, fmt.Errorf("duplicate %s %q", kind, name)
		}
		seen[name] = true
		total += value
	}
	return total, nil
}

func reconcileTelegram(ctx context.Context, api API, credentials CredentialReader, desired TelegramConfig) (bool, error) {
	current, err := api.Telegram(ctx)
	if err != nil {
		return false, err
	}
	types, err := notificationMask(desired.Events)
	if err != nil {
		return false, err
	}
	payload := telegramPayload{EmbedPoster: desired.EmbedPoster, Enabled: true, Types: types}
	if payload.Options.BotAPI, err = credentials.ReadRaw(desired.BotAPICredential); err != nil {
		return false, err
	}
	if payload.Options.BotUsername, err = credentials.ReadRaw(desired.BotUsernameCredential); err != nil {
		return false, err
	}
	if payload.Options.ChatID, err = credentials.ReadRaw(desired.ChatIDCredential); err != nil {
		return false, err
	}
	if desired.MessageThreadCredential != "" {
		if payload.Options.MessageThreadID, err = credentials.ReadRaw(desired.MessageThreadCredential); err != nil {
			return false, err
		}
	}
	payload.Options.SendSilently = desired.SendSilently
	encoded, err := json.Marshal(payload)
	if err != nil {
		return false, fmt.Errorf("encode Telegram settings: %w", err)
	}
	var updated seerrapi.TelegramSettings
	if err := json.Unmarshal(encoded, &updated); err != nil {
		return false, fmt.Errorf("decode generated Telegram settings: %w", err)
	}
	if reflect.DeepEqual(current, updated) {
		return false, nil
	}
	return true, api.UpdateTelegram(ctx, updated)
}
