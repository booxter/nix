package statemigration

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/queueaction"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func writeRecord(t *testing.T, path string, record any) {
	t.Helper()
	data, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCompletedImportWithoutPlanningCaseIsPreserved(t *testing.T) {
	root := t.TempDir()
	writeRecord(t, filepath.Join(root, "lidarr-repair-controller/imports/orphan.json"), lidarrrepair.ImportExecution{
		CaseID:        "sha256:orphan",
		QueueID:       42,
		AlbumID:       7,
		State:         lidarrrepair.Imported,
		Tracks:        []lidarrrepair.ImportExecutionTrack{{TrackID: 1, DownloadID: "download"}},
		Confirmations: []lidarr.ImportedTrack{{HistoryID: 99}},
	})
	batch, err := Convert(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(batch) != 1 || batch[0].Job.State != jobs.Imported || len(batch[0].Attempts) != 1 {
		t.Fatalf("orphan import lost: %+v", batch)
	}
	var receipt []lidarr.ImportedTrack
	if err := json.Unmarshal(batch[0].Attempts[0].ImportReceipt, &receipt); err != nil {
		t.Fatal(err)
	}
	if len(receipt) != 1 || receipt[0].HistoryID != 99 {
		t.Fatalf("receipt changed: %+v", receipt)
	}
}

func TestUnresolvedImportPreventsCutover(t *testing.T) {
	root := t.TempDir()
	writeRecord(t, filepath.Join(root, "lidarr-repair-controller/imports/pending.json"), lidarrrepair.ImportExecution{
		CaseID:  "sha256:pending",
		QueueID: 42,
		State:   lidarrrepair.ImportRequested,
		Tracks:  []lidarrrepair.ImportExecutionTrack{{TrackID: 1, DownloadID: "download"}},
	})
	if _, err := Convert(root, nil); err == nil {
		t.Fatal("converted an unresolved external import")
	}
}

func TestPendingGuidanceAndFailedRemovalSurviveConversion(t *testing.T) {
	root := t.TempDir()
	at := time.Now().UTC()
	repairCase := lidarrcontracts.Case{
		CaseID:     "sha256:album",
		ObservedAt: at,
		Queue:      lidarrcontracts.Queue{QueueID: 42, Title: "Album"},
	}
	caseData, err := json.Marshal(repairCase)
	if err != nil {
		t.Fatal(err)
	}
	writeRecord(t, filepath.Join(root, "lidarr-repair-controller/cases/album.json"), lidarrCase{
		CaseID: repairCase.CaseID,
		Record: lidarrrepair.Record{
			QueueID:  42,
			Case:     caseData,
			Bindings: []lidarrrepair.ImportBinding{{DownloadID: "download"}},
		},
	})
	writeRecord(t, filepath.Join(root, "lidarr-repair-controller/planning/album.json"), planning.StoredResult{
		CaseID:   repairCase.CaseID,
		Decision: json.RawMessage(`{"action":"no_repair","explanation":"ambiguous"}`),
	})
	writeRecord(t, filepath.Join(root, "media-repair-reconsideration/lidarr/guidance.json"), reconsideration.Request{
		CaseID:    repairCase.CaseID,
		RequestID: "sha256:guidance",
		Guidance:  "use the deluxe release",
		CreatedAt: at.Add(time.Minute),
	})
	batch, err := Convert(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(batch) != 1 || batch[0].Job.Guidance != "use the deluxe release" ||
		batch[0].Job.PendingAction != jobs.Reconsider || batch[0].Job.State != jobs.Observed {
		t.Fatalf("pending guidance lost: %+v", batch)
	}

	writeRecord(t, filepath.Join(root, "media-repair-actions/lidarr/remove.json"), queueaction.Request{
		RequestID: "sha256:remove",
		Queue:     queueaction.QueueIdentity{QueueID: 42, DownloadID: "download"},
	})
	writeRecord(t, filepath.Join(root, "lidarr-repair-controller/queue-action-results/remove.json"), queueaction.Result{
		State:   queueaction.StateFailed,
		Failure: "Lidarr returned HTTP 500",
	})
	batch, err = Convert(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if batch[0].Job.PendingAction != jobs.Delete || batch[0].Job.Reason != "Lidarr returned HTTP 500" {
		t.Fatalf("failed deletion lost: %+v", batch[0].Job)
	}
}
