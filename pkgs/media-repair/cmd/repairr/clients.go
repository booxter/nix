package main

import (
	"net/http"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/archivematerialize"
	"github.com/booxter/nix-config/media-repair/internal/downloadsource"
	"github.com/booxter/nix-config/media-repair/internal/filesystem"
	"github.com/booxter/nix-config/media-repair/internal/inspection"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/plannerclient"
	"github.com/booxter/nix-config/media-repair/internal/radarr"
	"github.com/booxter/nix-config/media-repair/internal/repairlidarr"
	"github.com/booxter/nix-config/media-repair/internal/repairradarr"
	"github.com/booxter/nix-config/media-repair/internal/sabnzbd"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"github.com/booxter/nix-config/media-repair/internal/transmission"
	"github.com/booxter/nix-config/media-repair/internal/workerclient"
)

type wallClock struct{}

func (wallClock) Now() time.Time {
	return time.Now().UTC()
}

func (configuration config) services(
	httpClient *http.Client,
	planner *plannerclient.Client,
	media *workerclient.Client,
) (*repairradarr.Adapter, *repairlidarr.Adapter, error) {
	radarrKey, err := servarr.ReadAPIKey("Radarr", configuration.Radarr.APIKeyFile)
	if err != nil {
		return nil, nil, err
	}
	radarrClient, err := radarr.New(configuration.Radarr.URL, radarrKey, httpClient)
	if err != nil {
		return nil, nil, err
	}

	lidarrKey, err := servarr.ReadAPIKey("Lidarr", configuration.Lidarr.APIKeyFile)
	if err != nil {
		return nil, nil, err
	}
	lidarrClient, err := lidarr.New(configuration.Lidarr.URL, lidarrKey, httpClient)
	if err != nil {
		return nil, nil, err
	}

	downloads, err := configuration.downloads(httpClient)
	if err != nil {
		return nil, nil, err
	}
	archives, err := archivematerialize.New(media)
	if err != nil {
		return nil, nil, err
	}
	inspector, err := inspection.New(inspection.Dependencies{
		Clock:             wallClock{},
		Radarr:            radarrClient,
		Downloads:         downloads,
		Files:             filesystem.New(),
		Probes:            media,
		Playlists:         media,
		DVDs:              media,
		Archives:          archives,
		CollectionTimeout: mediaTimeout,
	})
	if err != nil {
		return nil, nil, err
	}

	return &repairradarr.Adapter{
			Client:        radarrClient,
			Inspector:     inspector,
			Media:         media,
			Planner:       planner,
			Stabilization: queueInterval,
			Now:           wallClock{}.Now,
		}, &repairlidarr.Adapter{
			Client:    lidarrClient,
			Inspector: lidarrrepair.NewEvidenceCollector(lidarrClient, media),
			Planner:   planner,
		}, nil
}

func (configuration config) downloads(httpClient *http.Client) (*downloadsource.Resolver, error) {
	torrents, err := transmission.New(configuration.TransmissionURL, requestTimeout, httpClient)
	if err != nil {
		return nil, err
	}
	sabKey, err := servarr.ReadAPIKey("SABnzbd", configuration.SABnzbdKeyFile)
	if err != nil {
		return nil, err
	}
	usenet, err := sabnzbd.New(configuration.SABnzbdURL, sabKey, requestTimeout, httpClient)
	if err != nil {
		return nil, err
	}

	return downloadsource.New(
		downloadsource.Registration{Protocol: "torrent", ClientName: "Transmission", Reader: torrents},
		downloadsource.Registration{Protocol: "usenet", ClientName: "SABnzbd", Reader: usenet},
	)
}
