package servarr

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/golusoris/goenvoy/arr/radarr"
	"github.com/golusoris/goenvoy/arr/sonarr"
	"github.com/golusoris/goenvoy/arr/v2"
)

type Item struct {
	ID         int
	ExternalID int
	Title      string
	Tags       []int
}

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

func (catalog *Catalog) Items(
	ctx context.Context,
	kind seerr.ServiceKind,
	service seerr.Service,
) ([]Item, error) {
	switch kind {
	case seerr.Radarr:
		movies, err := catalog.Movies(ctx, service)
		if err != nil {
			return nil, err
		}
		items := make([]Item, len(movies))
		for index, movie := range movies {
			items[index] = Item{
				ID:         movie.ID,
				ExternalID: movie.TmdbID,
				Title:      movie.Title,
				Tags:       movie.Tags,
			}
		}
		return items, nil
	case seerr.Sonarr:
		series, err := catalog.Series(ctx, service)
		if err != nil {
			return nil, err
		}
		items := make([]Item, len(series))
		for index, item := range series {
			items[index] = Item{
				ID:         item.ID,
				ExternalID: item.TvdbID,
				Title:      item.Title,
				Tags:       item.Tags,
			}
		}
		return items, nil
	default:
		return nil, fmt.Errorf("unsupported service kind %q", kind)
	}
}

func (catalog *Catalog) Tags(
	ctx context.Context,
	kind seerr.ServiceKind,
	service seerr.Service,
) ([]arr.Tag, error) {
	switch kind {
	case seerr.Radarr:
		client, err := catalog.radarrClient(service)
		if err != nil {
			return nil, err
		}
		return client.GetTags(ctx)
	case seerr.Sonarr:
		client, err := catalog.sonarrClient(service)
		if err != nil {
			return nil, err
		}
		return client.GetTags(ctx)
	default:
		return nil, fmt.Errorf("unsupported service kind %q", kind)
	}
}

func (catalog *Catalog) CreateTag(
	ctx context.Context,
	kind seerr.ServiceKind,
	service seerr.Service,
	label string,
) (arr.Tag, error) {
	switch kind {
	case seerr.Radarr:
		client, err := catalog.radarrClient(service)
		if err != nil {
			return arr.Tag{}, err
		}
		tag, err := client.CreateTag(ctx, label)
		if err != nil {
			return arr.Tag{}, err
		}
		return *tag, nil
	case seerr.Sonarr:
		client, err := catalog.sonarrClient(service)
		if err != nil {
			return arr.Tag{}, err
		}
		tag, err := client.CreateTag(ctx, label)
		if err != nil {
			return arr.Tag{}, err
		}
		return *tag, nil
	default:
		return arr.Tag{}, fmt.Errorf("unsupported service kind %q", kind)
	}
}

func (catalog *Catalog) AddTag(
	ctx context.Context,
	kind seerr.ServiceKind,
	service seerr.Service,
	itemIDs []int,
	tagID int,
) error {
	switch kind {
	case seerr.Radarr:
		client, err := catalog.radarrClient(service)
		if err != nil {
			return err
		}
		return client.EditMovies(ctx, &radarr.MovieEditorResource{
			MovieIDs:  itemIDs,
			Tags:      []int{tagID},
			ApplyTags: "add",
		})
	case seerr.Sonarr:
		client, err := catalog.sonarrClient(service)
		if err != nil {
			return err
		}
		_, err = client.EditSeries(ctx, &sonarr.SeriesEditorResource{
			SeriesIDs: itemIDs,
			Tags:      []int{tagID},
			ApplyTags: "add",
		})
		return err
	default:
		return fmt.Errorf("unsupported service kind %q", kind)
	}
}
