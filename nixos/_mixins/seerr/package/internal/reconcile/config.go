package reconcile

import (
	"encoding/json"
	"fmt"
	"os"
)

type Config struct {
	Main     MainConfig      `json:"main"`
	Jellyfin JellyfinConfig  `json:"jellyfin"`
	Metadata MetadataConfig  `json:"metadata"`
	Radarr   []ServarrConfig `json:"radarr"`
	Sonarr   []ServarrConfig `json:"sonarr"`
	Telegram *TelegramConfig `json:"telegram"`
}

type MainConfig struct {
	DefaultPermissions []string `json:"default_permissions"`
	LocalLogin         bool     `json:"local_login"`
	MediaServerLogin   bool     `json:"media_server_login"`
	PartialRequests    bool     `json:"partial_requests"`
	SpecialEpisodes    bool     `json:"special_episodes"`
}

type JellyfinConfig struct {
	URL              string   `json:"url"`
	APIKeyCredential string   `json:"api_key_credential"`
	Libraries        []string `json:"libraries"`
}

type MetadataConfig struct {
	Anime  string `json:"anime"`
	Series string `json:"series"`
}

type Credential struct {
	Field  string `json:"field"`
	Format string `json:"format"`
	Name   string `json:"name"`
}

type ServarrConfig struct {
	API                 string     `json:"api"`
	AvailabilitySync    bool       `json:"availability_sync"`
	Credential          Credential `json:"credential"`
	Default             bool       `json:"default"`
	DisplayName         string     `json:"display_name"`
	LibraryPath         string     `json:"library_path"`
	MinimumAvailability string     `json:"minimum_availability,omitempty"`
	MonitorNewItems     string     `json:"monitor_new_items,omitempty"`
	Profile             string     `json:"profile"`
	SearchRequests      bool       `json:"search_requests"`
	SeasonFolders       bool       `json:"season_folders,omitempty"`
	TagRequests         bool       `json:"tag_requests"`
}

type TelegramConfig struct {
	BotAPICredential        string   `json:"bot_api_credential"`
	BotUsernameCredential   string   `json:"bot_username_credential"`
	ChatIDCredential        string   `json:"chat_id_credential"`
	EmbedPoster             bool     `json:"embed_poster"`
	MessageThreadCredential string   `json:"message_thread_credential,omitempty"`
	SendSilently            bool     `json:"send_silently"`
	Events                  []string `json:"events"`
}

func ReadConfig(path string) (Config, error) {
	payload, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read configuration: %w", err)
	}
	var config Config
	if err := json.Unmarshal(payload, &config); err != nil {
		return Config{}, fmt.Errorf("decode configuration: %w", err)
	}
	return config, nil
}
