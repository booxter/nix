package repairlidarr

import (
	"context"
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func (adapter *Adapter) Observe(ctx context.Context, previous []jobs.Job) (repair.Observation, error) {
	queue, err := adapter.Client.ReadQueue(ctx)
	if err != nil {
		return repair.Observation{}, err
	}

	stored := make(map[jobs.QueueKey]jobs.Job, len(previous))
	for _, job := range previous {
		stored[jobs.QueueKey{QueueID: job.QueueID, DownloadID: job.DownloadID}] = job
	}

	observed := repair.Observation{}
	complete, err := lidarr.FinalizationCandidates(ctx, adapter.Client)
	if err != nil {
		return repair.Observation{}, err
	}
	for _, entry := range complete {
		observed.Complete = append(observed.Complete, jobs.QueueKey{QueueID: entry.QueueID, DownloadID: entry.DownloadID})
	}
	for _, entry := range queue {
		key := jobs.QueueKey{QueueID: entry.ID, DownloadID: entry.DownloadID}
		observed.Queue = append(observed.Queue, key)
		job := jobs.Job{QueueID: entry.ID, DownloadID: entry.DownloadID, Title: entry.Title}
		prior := stored[key]
		if prior.State == jobs.Running || prior.State == jobs.Importing || prior.State == jobs.Imported {
			observed.Jobs = append(observed.Jobs, job)
			continue
		}

		var record *lidarrrepair.Record
		if len(prior.Evidence) != 0 {
			record = &lidarrrepair.Record{}
			if err := json.Unmarshal(prior.Evidence, record); err != nil {
				return repair.Observation{}, err
			}
		}

		evidence, err := adapter.Inspector.Inspect(ctx, entry, record)
		if err != nil {
			job.CollectionError = err.Error()
		} else {
			job.SourceFingerprint = evidence.Case.CaseID
			job.Evidence, err = encodeEvidence(evidence)
			if err != nil {
				return repair.Observation{}, err
			}
		}

		observed.Jobs = append(observed.Jobs, job)
	}

	return observed, nil
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
	result := repair.Decision{Data: data, Repair: decision.Kind != lidarrcontracts.ActionNoRepair}
	if decision.NoRepair != nil {
		result.Reason = decision.NoRepair.Explanation
	}

	return result, err
}

func (adapter *Adapter) Ready(jobs.Job) bool {
	return true
}
