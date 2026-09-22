package lidarr

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/servarr"
	"golift.io/starr"
	starrLidarr "golift.io/starr/lidarr"
)

type ManualImportQuery struct {
	Folder     string
	DownloadID string
	ArtistID   int64
}

type AudioTags struct {
	Title        string
	Artist       string
	Album        string
	TrackNumbers []int
	DiscNumber   int
	DiscCount    int
	Year         int
	DurationMS   int64
	Format       string
	BitRate      int64
	Channels     int
	Bits         int
	SampleRate   int
}

type ManualImportRejection struct {
	Type   string
	Reason string
}

type ManualImport struct {
	ID                      int64
	Path                    string
	Name                    string
	SizeBytes               int64
	ArtistID                int64
	AlbumID                 int64
	AlbumReleaseID          int64
	TrackIDs                []int64
	Quality                 *starr.Quality
	DownloadID              string
	IndexerFlags            int
	DisableReleaseSwitching bool
	AudioTags               *AudioTags
	Rejections              []ManualImportRejection
}

func (client *Client) ReadManualImports(
	ctx context.Context,
	query ManualImportQuery,
) ([]ManualImport, error) {
	if query.Folder == "" || strings.ContainsRune(query.Folder, '\x00') ||
		query.DownloadID == "" || strings.ContainsRune(query.DownloadID, '\x00') || query.ArtistID <= 0 {
		return nil, fmt.Errorf("Lidarr manual-import query is incomplete")
	}
	items, err := client.api.ManualImportContext(ctx, &starrLidarr.ManualImportParams{
		Folder: query.Folder, DownloadID: query.DownloadID, ArtistID: query.ArtistID,
		ReplaceExistingFiles: false, FilterExistingFiles: false,
	})
	if err != nil {
		return nil, servarr.NormalizeRequestError("Lidarr", "inspect Lidarr manual imports", err)
	}
	imports := make([]ManualImport, len(items))
	seen := make(map[string]struct{}, len(items))
	for index, item := range items {
		mapped, mapErr := mapManualImport(item, query)
		if mapErr != nil {
			return nil, fmt.Errorf("Lidarr manual-import item %d: %w", index, mapErr)
		}
		if _, duplicate := seen[mapped.Path]; duplicate {
			return nil, fmt.Errorf("Lidarr manual imports contain duplicate path %q", mapped.Path)
		}
		seen[mapped.Path] = struct{}{}
		imports[index] = mapped
	}
	sort.Slice(imports, func(left, right int) bool { return imports[left].Path < imports[right].Path })
	return imports, nil
}

func mapManualImport(item *starrLidarr.ManualImportOutput, query ManualImportQuery) (ManualImport, error) {
	if item == nil || item.ID < 0 || item.Path == "" || strings.ContainsRune(item.Path, '\x00') ||
		item.Name == "" || strings.ContainsRune(item.Name, '\x00') || item.Size <= 0 ||
		item.DownloadID != query.DownloadID {
		return ManualImport{}, fmt.Errorf("manual-import identity is incomplete")
	}
	result := ManualImport{
		ID: item.ID, Path: item.Path, Name: item.Name, SizeBytes: int64(item.Size),
		AlbumReleaseID: item.AlbumReleaseID, DownloadID: item.DownloadID,
		Quality: cloneQuality(item.Quality), DisableReleaseSwitching: item.DisableReleaseSwitching,
	}
	if item.Artist != nil {
		result.ArtistID = item.Artist.ID
	}
	if item.Album != nil {
		result.AlbumID = item.Album.ID
	}
	for index, track := range item.Tracks {
		if track == nil || track.ID <= 0 {
			return ManualImport{}, fmt.Errorf("manual-import track %d is incomplete", index)
		}
		result.TrackIDs = append(result.TrackIDs, track.ID)
	}
	for index, rejection := range item.Rejections {
		if rejection == nil || strings.TrimSpace(rejection.Type) == "" ||
			strings.TrimSpace(rejection.Reason) == "" {
			return ManualImport{}, fmt.Errorf("manual-import rejection %d is incomplete", index)
		}
		result.Rejections = append(result.Rejections, ManualImportRejection{
			Type: rejection.Type, Reason: rejection.Reason,
		})
	}
	result.AudioTags = mapAudioTags(item.AudioTags)
	return result, nil
}

func mapAudioTags(tags *starrLidarr.AudioTags) *AudioTags {
	if tags == nil {
		return nil
	}
	result := &AudioTags{
		Title: tags.Title, Artist: tags.ArtistTitle, Album: tags.AlbumTitle,
		TrackNumbers: append([]int(nil), tags.TrackNumbers...), DiscNumber: tags.DiscNumber,
		DiscCount: tags.DiscCount, Year: tags.Year, DurationMS: tags.Duration.Duration.Milliseconds(),
	}
	if tags.MediaInfo != nil {
		result.Format = tags.MediaInfo.AudioFormat
		result.BitRate = tags.MediaInfo.AudioBitrate
		result.Channels = tags.MediaInfo.AudioChannels
		result.Bits = tags.MediaInfo.AudioBits
		result.SampleRate = tags.MediaInfo.AudioSampleRate
	}
	return result
}

func cloneQuality(quality *starr.Quality) *starr.Quality {
	if quality == nil {
		return nil
	}
	cloned := *quality
	if quality.Quality != nil {
		base := *quality.Quality
		cloned.Quality = &base
	}
	if quality.Revision != nil {
		revision := *quality.Revision
		cloned.Revision = &revision
	}
	cloned.Items = nil
	return &cloned
}
