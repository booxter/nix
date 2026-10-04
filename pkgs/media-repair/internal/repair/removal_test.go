package repair

import (
	"context"
	"testing"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
)

type removalQueue struct {
	entries []queuefinalize.Entry
	retain  bool
}

func (queue *removalQueue) RemovalQueue(context.Context) ([]queuefinalize.Entry, error) {
	return queue.entries, nil
}

func (queue *removalQueue) FinalizeQueue(_ context.Context, id int64) error {
	for index, entry := range queue.entries {
		if entry.QueueID == id {
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

func TestRemovalFollowsChangedQueueID(t *testing.T) {
	for _, retain := range []bool{false, true} {
		queue := &removalQueue{retain: retain, entries: []queuefinalize.Entry{
			{QueueID: 20, DownloadID: "download", Status: "completed", TrackedDownloadStatus: "warning", SubjectID: 1},
		}}
		err := RemoveTracking(context.Background(), queue, jobs.Job{QueueID: 10, DownloadID: "download"})
		if (err != nil) != retain {
			t.Fatalf("retain=%t: removal result %v, queue %+v", retain, err, queue.entries)
		}
		if !retain && len(queue.entries) != 0 {
			t.Fatal("reported removal without deleting the current entry")
		}
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
