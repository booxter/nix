package repairlidarr

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"strings"

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

	stored := make([]jobs.QueueKey, len(previous))
	for index, job := range previous {
		stored[index] = job.QueueKey()
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
		index, err := jobs.MatchQueue(key, stored)
		if err != nil {
			return repair.Observation{}, err
		}
		var prior jobs.Job
		if index >= 0 {
			prior = previous[index]
		}
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
			job.PlanningFingerprint, err = planningFingerprint(evidence.Case)
			if err != nil {
				return repair.Observation{}, err
			}
			if record != nil {
				priorCase, decodeErr := lidarrcontracts.DecodeCase(record.Case)
				if decodeErr != nil {
					return repair.Observation{}, decodeErr
				}
				if prior.PlanningFingerprint == "" {
					job.PreviousPlanningFingerprint, err = planningFingerprint(priorCase)
					if err != nil {
						return repair.Observation{}, err
					}
				}
				job.PlanningChange = planningChange(priorCase, evidence.Case)
			}
			job.Evidence, err = encodeEvidence(evidence)
			if err != nil {
				return repair.Observation{}, err
			}
		}

		observed.Jobs = append(observed.Jobs, job)
	}

	return observed, nil
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

func planningFingerprint(repairCase lidarrcontracts.Case) (string, error) {
	inputs := planningCaseInputs(repairCase)
	data, err := json.Marshal(inputs)
	if err != nil {
		return "", fmt.Errorf("encode Lidarr planning inputs: %w", err)
	}
	digest := sha256.Sum256(data)
	return fmt.Sprintf("sha256:%x", digest), nil
}

func planningChange(previous, current lidarrcontracts.Case) string {
	before, after := planningCaseInputs(previous), planningCaseInputs(current)
	var changes []string
	if !reflect.DeepEqual(before.Artifacts, after.Artifacts) {
		changes = append(changes, "audio files")
	}
	if before.Album != after.Album {
		changes = append(changes, "target album")
	}
	if !reflect.DeepEqual(before.Releases, after.Releases) {
		changes = append(changes, "release catalog")
	}
	if !reflect.DeepEqual(before.Tracks, after.Tracks) {
		changes = append(changes, "track catalog/status")
	}
	return strings.Join(changes, ", ")
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
