package repairlidarr

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/planning"
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
			return jobs.Job{QueueID: entry.ID, DownloadID: entry.DownloadID, Title: entry.Title}
		},
		Inspect:    adapter.inspectAlbum,
		StopReason: albumStopReason,
		EncodeCase: encodeEvidence,
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

func albumStopReason(result lidarrrepair.CollectionResult) jobs.Outcome {
	if len(result.Findings) > 0 {
		return jobs.OutcomeQueueNotReady
	}
	var rejection *materialize.Rejection
	if errors.As(result.Err, &rejection) && rejection.Reason == materialize.FailureInvalidCueSheet {
		return jobs.OutcomeInvalidCueSheet
	}
	return jobs.OutcomeOther
}

type planningInputs struct {
	Album     lidarrcontracts.Album      `json:"album"`
	Releases  []lidarrcontracts.Release  `json:"releases"`
	Tracks    []lidarrcontracts.Track    `json:"tracks"`
	Artifacts []lidarrcontracts.Artifact `json:"artifacts"`
}

func planningCaseInputs(repairCase lidarrcontracts.Case) planningInputs {
	inputs := planningInputs{
		Album: repairCase.Album, Releases: slices.Clone(repairCase.Releases),
		Tracks: slices.Clone(repairCase.Tracks), Artifacts: slices.Clone(repairCase.Artifacts),
	}
	sort.Slice(inputs.Releases, func(i, j int) bool { return inputs.Releases[i].ReleaseID < inputs.Releases[j].ReleaseID })
	sort.Slice(inputs.Tracks, func(i, j int) bool { return inputs.Tracks[i].TrackID < inputs.Tracks[j].TrackID })
	sort.Slice(inputs.Artifacts, func(i, j int) bool { return inputs.Artifacts[i].ArtifactID < inputs.Artifacts[j].ArtifactID })
	return inputs
}

func (adapter *Adapter) PlanningInputs(data json.RawMessage) (planning.Inputs, error) {
	var record lidarrrepair.Record
	if err := json.Unmarshal(data, &record); err != nil {
		return planning.Inputs{}, err
	}
	repairCase, err := lidarrcontracts.DecodeCase(record.Case)
	if err != nil {
		return planning.Inputs{}, err
	}
	return planning.NewInputs(planningCaseInputs(repairCase))
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

func (adapter *Adapter) Plan(ctx context.Context, job jobs.Job) (repair.Decision, error) {
	var record lidarrrepair.Record
	if err := json.Unmarshal(job.Evidence, &record); err != nil {
		return repair.Decision{}, err
	}
	repairCase, err := lidarrcontracts.DecodeCase(record.Case)
	if err != nil {
		return repair.Decision{}, err
	}

	decision, err := adapter.Planner.PlanLidarr(ctx, repairCase, repair.Guidance(job))
	if err != nil {
		return repair.Decision{}, err
	}

	if err := lidarrrepair.ValidateDecision(repairCase, decision); err != nil {
		return repair.Decision{}, err
	}

	data, err := lidarrcontracts.EncodeDecision(decision)
	result := repair.Decision{Data: data, Result: planning.Result{Outcome: planning.Repair}}
	if stop := decision.NoRepair; stop != nil {
		result.Reason = stop.Explanation
		result.Result = planning.NoRepair(stop.Reason, Question(repairCase, stop.Reason))
	}

	return result, err
}

func (adapter *Adapter) Ready(jobs.Job) bool {
	return true
}
