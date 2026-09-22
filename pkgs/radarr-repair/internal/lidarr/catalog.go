package lidarr

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
	starrLidarr "golift.io/starr/lidarr"
)

type Album struct {
	ID           int64
	ArtistID     int64
	ArtistName   string
	Title        string
	Monitored    bool
	AnyReleaseOK bool
	Releases     []Release
}

type Release struct {
	ID             int64
	Title          string
	Disambiguation string
	Format         string
	Country        []string
	TrackCount     int
	MediumCount    int
	Monitored      bool
}

type Track struct {
	ID                  int64
	AlbumID             int64
	ArtistID            int64
	AbsoluteTrackNumber int
	TrackNumber         string
	MediumNumber        int
	Title               string
	DurationMS          int
	HasFile             bool
	TrackFileID         int64
}

func (client *Client) ReadAlbum(ctx context.Context, albumID int64) (Album, error) {
	if albumID <= 0 {
		return Album{}, fmt.Errorf("Lidarr album ID must be positive")
	}
	album, err := client.api.GetAlbumByIDContext(ctx, albumID)
	if err != nil {
		return Album{}, servarr.NormalizeRequestError("Lidarr", "read Lidarr album", err)
	}
	return mapAlbum(album, albumID)
}

func (client *Client) ReadTracks(ctx context.Context, albumID int64) ([]Track, error) {
	if albumID <= 0 {
		return nil, fmt.Errorf("Lidarr album ID must be positive")
	}
	items, err := client.api.GetTracksByAlbumContext(ctx, albumID)
	if err != nil {
		return nil, servarr.NormalizeRequestError("Lidarr", "read Lidarr album tracks", err)
	}
	tracks := make([]Track, len(items))
	seen := make(map[int64]struct{}, len(items))
	for index, item := range items {
		track, mapErr := mapTrack(item, albumID)
		if mapErr != nil {
			return nil, fmt.Errorf("Lidarr album track %d: %w", index, mapErr)
		}
		if _, duplicate := seen[track.ID]; duplicate {
			return nil, fmt.Errorf("Lidarr album contains duplicate track ID %d", track.ID)
		}
		seen[track.ID] = struct{}{}
		tracks[index] = track
	}
	sort.Slice(tracks, func(left, right int) bool {
		if tracks[left].AbsoluteTrackNumber == tracks[right].AbsoluteTrackNumber {
			return tracks[left].ID < tracks[right].ID
		}
		return tracks[left].AbsoluteTrackNumber < tracks[right].AbsoluteTrackNumber
	})
	return tracks, nil
}

func mapAlbum(item *starrLidarr.Album, expectedID int64) (Album, error) {
	if item == nil || item.ID != expectedID || item.ArtistID <= 0 || strings.TrimSpace(item.Title) == "" {
		return Album{}, fmt.Errorf("album identity is incomplete")
	}
	if item.Artist == nil || item.Artist.ID != item.ArtistID ||
		strings.TrimSpace(item.Artist.ArtistName) == "" {
		return Album{}, fmt.Errorf("album artist is incomplete")
	}
	releases := make([]Release, len(item.Releases))
	seen := make(map[int64]struct{}, len(item.Releases))
	for index, release := range item.Releases {
		if release == nil || release.ID <= 0 || release.AlbumID != item.ID ||
			strings.TrimSpace(release.Title) == "" || release.TrackCount <= 0 || release.MediumCount < 0 {
			return Album{}, fmt.Errorf("album release %d is incomplete", index)
		}
		if _, duplicate := seen[release.ID]; duplicate {
			return Album{}, fmt.Errorf("album contains duplicate release ID %d", release.ID)
		}
		seen[release.ID] = struct{}{}
		releases[index] = Release{
			ID: release.ID, Title: release.Title, Disambiguation: release.Disambiguation,
			Format: release.Format, Country: append([]string(nil), release.Country...),
			TrackCount: release.TrackCount, MediumCount: release.MediumCount,
			Monitored: release.Monitored,
		}
	}
	sort.Slice(releases, func(left, right int) bool { return releases[left].ID < releases[right].ID })
	return Album{
		ID: item.ID, ArtistID: item.ArtistID, ArtistName: item.Artist.ArtistName,
		Title: item.Title, Monitored: item.Monitored, AnyReleaseOK: item.AnyReleaseOk,
		Releases: releases,
	}, nil
}

func mapTrack(item *starrLidarr.Track, expectedAlbumID int64) (Track, error) {
	if item == nil || item.ID <= 0 || item.AlbumID != expectedAlbumID || item.ArtistID <= 0 ||
		item.AbsoluteTrackNumber <= 0 || item.MediumNumber <= 0 ||
		strings.TrimSpace(item.TrackNumber) == "" || strings.TrimSpace(item.Title) == "" ||
		item.Duration < 0 || item.TrackFileID < 0 {
		return Track{}, fmt.Errorf("track identity is incomplete")
	}
	return Track{
		ID: item.ID, AlbumID: item.AlbumID, ArtistID: item.ArtistID,
		AbsoluteTrackNumber: item.AbsoluteTrackNumber, TrackNumber: item.TrackNumber,
		MediumNumber: item.MediumNumber, Title: item.Title, DurationMS: item.Duration,
		HasFile: item.HasFile, TrackFileID: item.TrackFileID,
	}, nil
}
