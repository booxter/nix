package repairlidarr

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
)

func (adapter *Adapter) Observe(ctx context.Context, saved []jobs.Job) (repair.Observation, error) {
	return repair.QueuePoll[lidarr.QueueRecord, lidarrrepair.Evidence]{
		ReadQueue: adapter.Client.ReadQueue,
		FindComplete: func(ctx context.Context, queue []lidarr.QueueRecord) ([]queuefinalize.Entry, error) {
			return lidarr.FinalizationCandidates(ctx, adapter.Client, queue)
		},
		NewJob: func(entry lidarr.QueueRecord) jobs.Job {
			return jobs.Job{
				QueueID: entry.ID, DownloadID: entry.DownloadID, Title: entry.Title,
				TrackedDownloadState: entry.TrackedDownloadState,
			}
		},
		Inspect:      adapter.inspectAlbum,
		ErrorOutcome: albumInspectionError,
		EncodeCase:   encodeEvidence,
	}.Observe(ctx, saved)
}

// The previous album inspection can supply files already prepared in the workspace.
func (adapter *Adapter) inspectAlbum(ctx context.Context, entry lidarr.QueueRecord, saved json.RawMessage) lidarrrepair.CollectionResult {
	var record *lidarrrepair.Record
	if len(saved) != 0 {
		record = &lidarrrepair.Record{}
		if err := json.Unmarshal(saved, record); err != nil {
			return lidarrrepair.CollectionResult{Err: fmt.Errorf("read saved album case: %w", err)}
		}
	}

	return adapter.Inspector.Inspect(ctx, entry, record)
}

func albumInspectionError(err error) jobs.Outcome {
	var rejection *materialize.Rejection
	if errors.As(err, &rejection) && rejection.Reason == materialize.FailureInvalidCueSheet {
		return jobs.OutcomeInvalidCueSheet
	}
	return jobs.OutcomeOther
}

func encodeEvidence(evidence lidarrrepair.Evidence) (jobs.InspectedCase, error) {
	data, err := lidarrcontracts.EncodeCase(evidence.Case)
	if err != nil {
		return jobs.InspectedCase{}, err
	}

	record, err := json.Marshal(lidarrrepair.Record{
		QueueID:           evidence.Queue.ID,
		SourceKind:        evidence.SourceKind,
		SourcePath:        evidence.SourcePath,
		SourceFingerprint: evidence.SourceFingerprint,
		WorkspaceRoot:     evidence.WorkspaceRoot,
		Case:              data,
		Bindings:          evidence.Bindings,
	})
	// The planner sees the prepared tracks. Identical tracks can come
	// from a replacement archive or a different download directory.
	source := strings.Join([]string{evidence.Case.CaseID, evidence.SourcePath, evidence.SourceFingerprint}, "\x00")
	fingerprint := fmt.Sprintf("sha256:%x", sha256.Sum256([]byte(source)))
	return jobs.InspectedCase{Fingerprint: fingerprint, Evidence: record}, err
}
