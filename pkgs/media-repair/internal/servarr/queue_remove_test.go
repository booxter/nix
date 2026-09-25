package servarr

import (
	"context"
	"testing"

	"golift.io/starr"
)

func TestRemoveQueueTrackingPreservesDownloadAndAvoidsBlocklist(t *testing.T) {
	t.Parallel()
	called := false
	err := RemoveQueueTracking(
		context.Background(), "Lidarr", 42,
		func(_ context.Context, queueID int64, options *starr.QueueDeleteOpts) error {
			called = true
			if queueID != 42 || options == nil || options.RemoveFromClient == nil ||
				*options.RemoveFromClient || options.BlockList || !options.SkipRedownload ||
				options.ChangeCategory {
				t.Fatalf("queue ID = %d, options = %#v", queueID, options)
			}
			return nil
		},
	)
	if err != nil || !called {
		t.Fatalf("called = %t, error = %v", called, err)
	}
}
