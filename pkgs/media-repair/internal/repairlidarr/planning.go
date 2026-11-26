package repairlidarr

import (
	"context"
	"encoding/json"
	"errors"
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
	return repair.QueuePoll[lidarr.QueueRecord]{
		ReadQueue: adapter.Client.ReadQueue,
		FindComplete: func(ctx context.Context, queue []lidarr.QueueRecord) ([]queuefinalize.Entry, error) {
			return lidarr.FinalizationCandidates(ctx, adapter.Client, queue)
		},
		NewJob: func(entry lidarr.QueueRecord) jobs.Job {
			return jobs.Job{QueueID: entry.ID, DownloadID: entry.DownloadID, Title: entry.Title}
		},
		Inspect: adapter.inspectJob,
	}.Observe(ctx, saved)
}

// The previous album inspection can supply files already prepared in the workspace.
func (adapter *Adapter) inspectJob(ctx context.Context, entry lidarr.QueueRecord, saved json.RawMessage, job *jobs.Job) error {
	var record *lidarrrepair.Record
	if len(saved) != 0 {
		record = &lidarrrepair.Record{}
		if err := json.Unmarshal(saved, record); err != nil {
			return err
		}
	}

	result := adapter.Inspector.Inspect(ctx, entry, record)
	switch {
	case len(result.Findings) > 0:
		job.CollectionError = strings.Join(result.Findings, ", ")
		job.CollectionOutcome = jobs.OutcomeQueueNotReady
	case result.Err != nil:
		job.CollectionError = result.Err.Error()
		job.CollectionOutcome = jobs.OutcomeOther
		var rejection *materialize.Rejection
		if errors.As(result.Err, &rejection) && rejection.Reason == materialize.FailureInvalidCueSheet {
			job.CollectionOutcome = jobs.OutcomeInvalidCueSheet
		}
	default:
		evidence := result.Case
		job.SourceFingerprint = evidence.Case.CaseID
		data, err := encodeEvidence(*evidence)
		if err != nil {
			return err
		}
		job.Evidence = data
	}
	return nil
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

func encodeEvidence(evidence lidarrrepair.Evidence) (json.RawMessage, error) {
	data, err := lidarrcontracts.EncodeCase(evidence.Case)
	if err != nil {
		return nil, err
	}

	return json.Marshal(lidarrrepair.Record{
		QueueID:           evidence.Queue.ID,
		SourceKind:        evidence.SourceKind,
		SourcePath:        evidence.SourcePath,
		SourceFingerprint: evidence.SourceFingerprint,
		WorkspaceRoot:     evidence.WorkspaceRoot,
		Case:              data,
		Bindings:          evidence.Bindings,
	})
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
