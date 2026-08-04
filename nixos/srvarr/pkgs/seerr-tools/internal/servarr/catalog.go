package servarr

import (
	"context"
	"time"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/golusoris/goenvoy/arr/radarr"
	"github.com/golusoris/goenvoy/arr/sonarr"
	"github.com/golusoris/goenvoy/arr/v2"
)

type Catalog struct {
	timeout time.Duration
	radarr  map[int]*radarr.Client
	sonarr  map[int]*sonarr.Client
}

func NewCatalog(timeout time.Duration) *Catalog {
	return &Catalog{
		timeout: timeout,
		radarr:  make(map[int]*radarr.Client),
		sonarr:  make(map[int]*sonarr.Client),
	}
}

func (catalog *Catalog) radarrClient(service seerr.Service) (*radarr.Client, error) {
	if client := catalog.radarr[service.ID]; client != nil {
		return client, nil
	}
	client, err := radarr.New(
		service.URL(),
		service.APIKey,
		arr.WithTimeout(catalog.timeout),
	)
	if err != nil {
		return nil, err
	}
	catalog.radarr[service.ID] = client
	return client, nil
}

func (catalog *Catalog) sonarrClient(service seerr.Service) (*sonarr.Client, error) {
	if client := catalog.sonarr[service.ID]; client != nil {
		return client, nil
	}
	client, err := sonarr.New(
		service.URL(),
		service.APIKey,
		arr.WithTimeout(catalog.timeout),
	)
	if err != nil {
		return nil, err
	}
	catalog.sonarr[service.ID] = client
	return client, nil
}

func (catalog *Catalog) Movies(ctx context.Context, service seerr.Service) ([]radarr.Movie, error) {
	client, err := catalog.radarrClient(service)
	if err != nil {
		return nil, err
	}
	return client.GetAllMovies(ctx)
}

func (catalog *Catalog) Series(ctx context.Context, service seerr.Service) ([]sonarr.Series, error) {
	client, err := catalog.sonarrClient(service)
	if err != nil {
		return nil, err
	}
	return client.GetAllSeries(ctx)
}

func (catalog *Catalog) EpisodeFiles(
	ctx context.Context,
	service seerr.Service,
	seriesID int,
) ([]sonarr.EpisodeFile, error) {
	client, err := catalog.sonarrClient(service)
	if err != nil {
		return nil, err
	}
	return client.GetEpisodeFiles(ctx, seriesID)
}
