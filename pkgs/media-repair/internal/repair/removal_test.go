package repair

import (
	"context"
	"errors"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type removalQueue struct {
	entries         []queuefinalize.Entry
	retain          bool
	downloadPresent bool
}

func (queue *removalQueue) InspectRemoval(context.Context, jobs.QueueKey) (jobs.InspectedCase, error) {
	return jobs.InspectedCase{Fingerprint: "movie"}, nil
}

func (queue *removalQueue) RemovalQueue(context.Context) ([]queuefinalize.Entry, error) {
	return queue.entries, nil
}

func (queue *removalQueue) FinalizeQueue(_ context.Context, id int64, removeFromClient bool) error {
	for index, entry := range queue.entries {
		if entry.QueueID == id {
			if removeFromClient {
				queue.downloadPresent = false
			}
			if queue.retain {
				queue.entries[index].QueueID++
			} else {
				queue.entries = append(queue.entries[:index], queue.entries[index+1:]...)
			}
			break
		}
	}
	return nil
}

func TestRemovalCleansSABnzbdAndPreservesOtherDownloads(t *testing.T) {
	for _, test := range []struct {
		name         string
		protocol     string
		client       string
		wantRetained bool
	}{
		{"sabnzbd", "usenet", "SABnzbd", false},
		{"torrent", "torrent", "Transmission", true},
		{"other usenet", "usenet", "NZBGet", true},
		{"missing client", "usenet", "", true},
		{"wrong protocol", "torrent", "SABnzbd", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			queue := &removalQueue{
				downloadPresent: true,
				entries: []queuefinalize.Entry{{
					QueueID: 20, DownloadID: "download", SubjectID: 1,
					Status: "completed", TrackedDownloadStatus: "warning",
					Protocol: test.protocol, DownloadClient: test.client,
				}},
			}
			err := RemoveTracking(context.Background(), queue, jobs.Job{QueueID: 20, DownloadID: "download", RemovalFingerprint: new("movie")})
			if err != nil {
				t.Fatal(err)
			}
			if len(queue.entries) != 0 || queue.downloadPresent != test.wantRetained {
				t.Fatalf("queue = %+v, download retained = %t", queue.entries, queue.downloadPresent)
			}
		})
	}
}

func TestRemovalFollowsChangedQueueID(t *testing.T) {
	for _, retain := range []bool{false, true} {
		queue := &removalQueue{retain: retain, entries: []queuefinalize.Entry{
			{QueueID: 20, DownloadID: "download", Status: "completed", TrackedDownloadStatus: "warning", SubjectID: 1},
		}}
		err := RemoveTracking(context.Background(), queue, jobs.Job{QueueID: 10, DownloadID: "download", RemovalFingerprint: new("")})
		if (err != nil) != retain {
			t.Fatalf("retain=%t: removal result %v, queue %+v", retain, err, queue.entries)
		}
		if !retain && len(queue.entries) != 0 {
			t.Fatal("reported removal without deleting the current entry")
		}
	}
}

func TestLegacyRemovalNeedsConfirmationOnlyIfStillQueued(t *testing.T) {
	job := jobs.Job{QueueID: 10, DownloadID: "download"}
	queue := &removalQueue{entries: []queuefinalize.Entry{
		{QueueID: 10, DownloadID: "download", Status: "completed", TrackedDownloadStatus: "warning", SubjectID: 1},
	}}
	var notice *jobs.RemovalNeedsConfirmation
	if err := RemoveTracking(context.Background(), queue, job); !errors.As(err, &notice) || len(queue.entries) != 1 {
		t.Fatalf("legacy request with no saved approval: %v, queue %+v", err, queue.entries)
	}
	queue.entries = nil
	if err := RemoveTracking(context.Background(), queue, job); err != nil {
		t.Fatalf("already removed: %v", err)
	}
}

func TestRemovalRejectsAmbiguousChangedQueueID(t *testing.T) {
	queue := &removalQueue{entries: []queuefinalize.Entry{
		{QueueID: 20, DownloadID: "download", Status: "completed", TrackedDownloadStatus: "warning", SubjectID: 1},
		{QueueID: 30, DownloadID: "download", Status: "completed", TrackedDownloadStatus: "warning", SubjectID: 2},
	}}
	err := RemoveTracking(context.Background(), queue, jobs.Job{QueueID: 10, DownloadID: "download"})
	if err == nil || len(queue.entries) != 2 {
		t.Fatalf("ambiguous download removed: %v, %+v", err, queue.entries)
	}
}
