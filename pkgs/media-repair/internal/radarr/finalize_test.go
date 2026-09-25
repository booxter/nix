package radarr

import (
	"context"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

type finalizationReader struct {
	queue []controller.RadarrQueueRecord
	movie controller.RadarrMovie
}

func (reader *finalizationReader) ReadQueue(context.Context) ([]controller.RadarrQueueRecord, error) {
	return append([]controller.RadarrQueueRecord(nil), reader.queue...), nil
}

func (reader *finalizationReader) ReadMovie(context.Context, int64) (controller.RadarrMovie, error) {
	return reader.movie, nil
}

func TestFinalizationCandidatesRequireExistingMovieFile(t *testing.T) {
	t.Parallel()
	movieID := int64(2)
	reader := &finalizationReader{
		queue: []controller.RadarrQueueRecord{{
			ID: 1, MovieID: &movieID, DownloadID: "download",
			Status: "completed", TrackedDownloadStatus: "warning",
		}},
		movie: controller.RadarrMovie{ID: movieID, HasFile: true},
	}
	candidates, err := FinalizationCandidates(context.Background(), reader)
	if err != nil || len(candidates) != 1 || candidates[0].SubjectID != movieID {
		t.Fatalf("candidates = %#v, error = %v", candidates, err)
	}
	reader.movie.HasFile = false
	candidates, err = FinalizationCandidates(context.Background(), reader)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("missing-file candidates = %#v, error = %v", candidates, err)
	}
}
