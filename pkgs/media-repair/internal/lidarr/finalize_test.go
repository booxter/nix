package lidarr

import (
	"context"
	"testing"
)

type finalizationReader struct {
	queue  []QueueRecord
	album  Album
	tracks []Track
}

func (reader *finalizationReader) ReadQueue(context.Context) ([]QueueRecord, error) {
	return append([]QueueRecord(nil), reader.queue...), nil
}

func (reader *finalizationReader) ReadAlbum(context.Context, int64) (Album, error) {
	return reader.album, nil
}

func (reader *finalizationReader) ReadReleaseTracks(context.Context, int64, int64) ([]Track, error) {
	return append([]Track(nil), reader.tracks...), nil
}

func TestFinalizationCandidatesRequireCompleteUniqueMonitoredRelease(t *testing.T) {
	t.Parallel()
	albumID := int64(3)
	artistID := int64(2)
	reader := &finalizationReader{
		queue: []QueueRecord{{
			ID: 1, AlbumID: &albumID, ArtistID: &artistID, DownloadID: "download",
			Status: "completed", TrackedDownloadStatus: "warning",
		}},
		album: Album{
			ID: albumID, ArtistID: artistID, Monitored: true,
			Releases: []Release{{ID: 4, Monitored: true, TrackCount: 2}},
		},
		tracks: []Track{
			{ID: 10, HasFile: true, TrackFileID: 20},
			{ID: 11, HasFile: true, TrackFileID: 21},
		},
	}
	candidates, err := FinalizationCandidates(context.Background(), reader)
	if err != nil || len(candidates) != 1 || candidates[0].SubjectID != albumID {
		t.Fatalf("candidates = %#v, error = %v", candidates, err)
	}
	reader.tracks[1].HasFile = false
	candidates, err = FinalizationCandidates(context.Background(), reader)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("incomplete candidates = %#v, error = %v", candidates, err)
	}
	reader.tracks[1].HasFile = true
	reader.album.Releases = append(reader.album.Releases, Release{ID: 5, Monitored: true, TrackCount: 2})
	candidates, err = FinalizationCandidates(context.Background(), reader)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("ambiguous candidates = %#v, error = %v", candidates, err)
	}
}

func TestFinalizationCandidatesRefuseUnresolvedQueueIdentity(t *testing.T) {
	t.Parallel()
	reader := &finalizationReader{queue: []QueueRecord{{
		ID: 1, DownloadID: "download", Status: "completed", TrackedDownloadStatus: "warning",
	}}}
	candidates, err := FinalizationCandidates(context.Background(), reader)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("candidates = %#v, error = %v", candidates, err)
	}
}
