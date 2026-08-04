package storage

import (
	"context"
	"fmt"
	"math"
	"sort"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/golusoris/goenvoy/arr/radarr"
	"github.com/golusoris/goenvoy/arr/sonarr"
)

type Catalog interface {
	Movies(context.Context, seerr.Service) ([]radarr.Movie, error)
	Series(context.Context, seerr.Service) ([]sonarr.Series, error)
	EpisodeFiles(context.Context, seerr.Service, int) ([]sonarr.EpisodeFile, error)
}

type UserRow struct {
	UserID           int     `json:"userId"`
	DisplayName      string  `json:"displayName"`
	Movies           int     `json:"movies"`
	Series           int     `json:"series"`
	Seasons          int     `json:"seasons"`
	Files            int     `json:"files"`
	MovieBytes       int64   `json:"movieBytes"`
	TVBytes          int64   `json:"tvBytes"`
	LogicalBytes     int64   `json:"logicalBytes"`
	AllocatedBytes   int64   `json:"allocatedBytes"`
	AllocatedPercent float64 `json:"allocatedPercent"`
	ExclusiveBytes   int64   `json:"exclusiveBytes"`
}

type Totals struct {
	DistinctBytes int64 `json:"distinctBytes"`
	MovieBytes    int64 `json:"movieBytes"`
	TVBytes       int64 `json:"tvBytes"`
	LogicalBytes  int64 `json:"logicalBytes"`
	Files         int   `json:"files"`
	SharedFiles   int   `json:"sharedFiles"`
}

type Unresolved struct {
	MoviesNotInRadarr   int `json:"moviesNotInRadarr"`
	MoviesWithoutFiles  int `json:"moviesWithoutFiles"`
	SeriesNotInSonarr   int `json:"seriesNotInSonarr"`
	SeasonsWithoutFiles int `json:"seasonsWithoutFiles"`
}

type RequestStats struct {
	Scanned  int `json:"scanned"`
	Eligible int `json:"eligible"`
	Skipped  int `json:"skipped"`
}

type Report struct {
	Users      []UserRow    `json:"users"`
	Totals     Totals       `json:"totals"`
	Unresolved Unresolved   `json:"unresolved"`
	Requests   RequestStats `json:"requests"`
}

type movieRequestKey struct {
	ServiceID int
	TmdbID    int
}

type seriesRequestKey struct {
	ServiceID    int
	TvdbID       int
	SeasonNumber int
}

type fileKey struct {
	Kind      string
	ServiceID int
	FileID    int
}

type movieKey struct {
	ServiceID int
	MovieID   int
}

type seriesKey struct {
	ServiceID int
	SeriesID  int
}

type seasonKey struct {
	ServiceID    int
	SeriesID     int
	SeasonNumber int
}

type attribution struct {
	users    map[int]seerr.User
	movies   map[movieRequestKey]map[int]bool
	series   map[seriesRequestKey]map[int]bool
	eligible int
}

func addUser(target map[int]bool, userID int) {
	if target != nil {
		target[userID] = true
	}
}

func requestsByUser(requests []seerr.Request, services map[string]map[int]seerr.Service) attribution {
	result := attribution{
		users:  make(map[int]seerr.User),
		movies: make(map[movieRequestKey]map[int]bool),
		series: make(map[seriesRequestKey]map[int]bool),
	}
	for _, request := range requests {
		if request.Status != seerr.RequestApproved && request.Status != seerr.RequestCompleted {
			continue
		}
		if request.RequestedBy == nil || request.RequestedBy.DisplayName == "" || request.Media == nil {
			continue
		}
		serviceID, ok := request.ServiceID()
		if !ok {
			continue
		}
		serviceKind := "sonarr"
		if request.Type == "movie" {
			serviceKind = "radarr"
		} else if request.Type != "tv" {
			continue
		}
		if _, ok := services[serviceKind][serviceID]; !ok {
			continue
		}
		user := *request.RequestedBy
		result.users[user.ID] = user
		if request.Type == "movie" {
			if request.Media.TmdbID == nil {
				continue
			}
			key := movieRequestKey{serviceID, *request.Media.TmdbID}
			if result.movies[key] == nil {
				result.movies[key] = make(map[int]bool)
			}
			addUser(result.movies[key], user.ID)
		} else {
			if request.Media.TvdbID == nil || len(request.Seasons) == 0 {
				continue
			}
			for _, season := range request.Seasons {
				key := seriesRequestKey{serviceID, *request.Media.TvdbID, season.Number}
				if result.series[key] == nil {
					result.series[key] = make(map[int]bool)
				}
				addUser(result.series[key], user.ID)
			}
		}
		result.eligible++
	}
	return result
}

func indexServices(radarrServices, sonarrServices []seerr.Service) map[string]map[int]seerr.Service {
	services := map[string]map[int]seerr.Service{
		"radarr": make(map[int]seerr.Service),
		"sonarr": make(map[int]seerr.Service),
	}
	for _, service := range radarrServices {
		services["radarr"][service.ID] = service
	}
	for _, service := range sonarrServices {
		services["sonarr"][service.ID] = service
	}
	return services
}

func addFile(
	fileUsers map[fileKey]map[int]bool,
	fileSizes map[fileKey]int64,
	key fileKey,
	size int64,
	users map[int]bool,
) bool {
	if size <= 0 {
		return false
	}
	fileSizes[key] = size
	if fileUsers[key] == nil {
		fileUsers[key] = make(map[int]bool)
	}
	for userID := range users {
		fileUsers[key][userID] = true
	}
	return true
}

func Build(
	ctx context.Context,
	requests []seerr.Request,
	radarrServices []seerr.Service,
	sonarrServices []seerr.Service,
	catalog Catalog,
) (Report, error) {
	services := indexServices(radarrServices, sonarrServices)
	desired := requestsByUser(requests, services)
	fileUsers := make(map[fileKey]map[int]bool)
	fileSizes := make(map[fileKey]int64)
	userMovies := make(map[int]map[movieKey]bool)
	userSeries := make(map[int]map[seriesKey]bool)
	userSeasons := make(map[int]map[seasonKey]bool)
	var unresolved Unresolved

	for serviceID, service := range services["radarr"] {
		movies, err := catalog.Movies(ctx, service)
		if err != nil {
			return Report{}, fmt.Errorf("read Radarr %q movies: %w", service.Name, err)
		}
		inventory := make(map[int]radarr.Movie, len(movies))
		for _, movie := range movies {
			inventory[movie.TmdbID] = movie
		}
		for key, users := range desired.movies {
			if key.ServiceID != serviceID {
				continue
			}
			movie, ok := inventory[key.TmdbID]
			if !ok {
				unresolved.MoviesNotInRadarr++
				continue
			}
			for userID := range users {
				if userMovies[userID] == nil {
					userMovies[userID] = make(map[movieKey]bool)
				}
				userMovies[userID][movieKey{serviceID, movie.ID}] = true
			}
			fileID := movie.ID
			size := movie.SizeOnDisk
			if movie.MovieFile != nil {
				fileID = movie.MovieFile.ID
				if size <= 0 {
					size = movie.MovieFile.Size
				}
			}
			if !addFile(fileUsers, fileSizes, fileKey{"movie", serviceID, fileID}, size, users) {
				unresolved.MoviesWithoutFiles++
			}
		}
	}

	for serviceID, service := range services["sonarr"] {
		series, err := catalog.Series(ctx, service)
		if err != nil {
			return Report{}, fmt.Errorf("read Sonarr %q series: %w", service.Name, err)
		}
		inventory := make(map[int]sonarr.Series, len(series))
		for _, item := range series {
			inventory[item.TvdbID] = item
		}
		filesBySeries := make(map[int]map[int][]sonarr.EpisodeFile)
		for key, users := range desired.series {
			if key.ServiceID != serviceID {
				continue
			}
			item, ok := inventory[key.TvdbID]
			if !ok {
				unresolved.SeriesNotInSonarr++
				continue
			}
			if filesBySeries[item.ID] == nil {
				files, err := catalog.EpisodeFiles(ctx, service, item.ID)
				if err != nil {
					return Report{}, fmt.Errorf("read Sonarr %q episode files: %w", service.Name, err)
				}
				filesBySeries[item.ID] = make(map[int][]sonarr.EpisodeFile)
				for _, file := range files {
					filesBySeries[item.ID][file.SeasonNumber] = append(
						filesBySeries[item.ID][file.SeasonNumber],
						file,
					)
				}
			}
			for userID := range users {
				if userSeries[userID] == nil {
					userSeries[userID] = make(map[seriesKey]bool)
					userSeasons[userID] = make(map[seasonKey]bool)
				}
				userSeries[userID][seriesKey{serviceID, item.ID}] = true
				userSeasons[userID][seasonKey{serviceID, item.ID, key.SeasonNumber}] = true
			}
			files := filesBySeries[item.ID][key.SeasonNumber]
			if len(files) == 0 {
				unresolved.SeasonsWithoutFiles++
				continue
			}
			for _, file := range files {
				addFile(
					fileUsers,
					fileSizes,
					fileKey{"episode", serviceID, file.ID},
					file.Size,
					users,
				)
			}
		}
	}

	perUserFiles := make(map[int]map[fileKey]bool)
	for key, users := range fileUsers {
		for userID := range users {
			if perUserFiles[userID] == nil {
				perUserFiles[userID] = make(map[fileKey]bool)
			}
			perUserFiles[userID][key] = true
		}
	}

	var report Report
	report.Unresolved = unresolved
	report.Requests = RequestStats{
		Scanned:  len(requests),
		Eligible: desired.eligible,
		Skipped:  len(requests) - desired.eligible,
	}
	for key, size := range fileSizes {
		report.Totals.DistinctBytes += size
		if key.Kind == "movie" {
			report.Totals.MovieBytes += size
		} else {
			report.Totals.TVBytes += size
		}
		if len(fileUsers[key]) > 1 {
			report.Totals.SharedFiles++
		}
	}
	report.Totals.Files = len(fileSizes)
	for userID, user := range desired.users {
		row := UserRow{
			UserID:      userID,
			DisplayName: user.DisplayName,
			Movies:      len(userMovies[userID]),
			Series:      len(userSeries[userID]),
			Seasons:     len(userSeasons[userID]),
			Files:       len(perUserFiles[userID]),
		}
		allocated := float64(0)
		for key := range perUserFiles[userID] {
			size := fileSizes[key]
			row.LogicalBytes += size
			if key.Kind == "movie" {
				row.MovieBytes += size
			} else {
				row.TVBytes += size
			}
			allocated += float64(size) / float64(len(fileUsers[key]))
			if len(fileUsers[key]) == 1 {
				row.ExclusiveBytes += size
			}
		}
		row.AllocatedBytes = int64(math.Round(allocated))
		if report.Totals.DistinctBytes > 0 {
			row.AllocatedPercent = allocated / float64(report.Totals.DistinctBytes) * 100
		}
		report.Totals.LogicalBytes += row.LogicalBytes
		report.Users = append(report.Users, row)
	}
	sort.Slice(report.Users, func(left, right int) bool {
		if report.Users[left].LogicalBytes == report.Users[right].LogicalBytes {
			return report.Users[left].UserID < report.Users[right].UserID
		}
		return report.Users[left].LogicalBytes > report.Users[right].LogicalBytes
	})
	return report, nil
}
