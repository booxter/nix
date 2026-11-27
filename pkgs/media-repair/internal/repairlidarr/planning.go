package repairlidarr

import (
	"context"
	"encoding/json"
	"slices"
	"sort"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

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

func readPlanningCase(data json.RawMessage) (lidarrcontracts.Case, error) {
	var record lidarrrepair.Record
	if err := json.Unmarshal(data, &record); err != nil {
		return lidarrcontracts.Case{}, err
	}
	return lidarrcontracts.DecodeCase(record.Case)
}

func (adapter *Adapter) PlanningInputs(data json.RawMessage) (planning.Inputs, error) {
	repairCase, err := readPlanningCase(data)
	if err != nil {
		return planning.Inputs{}, err
	}
	return planning.NewInputs(planningCaseInputs(repairCase))
}

func (adapter *Adapter) Plan(ctx context.Context, job jobs.Job) (repair.Decision, error) {
	repairCase, err := readPlanningCase(job.Evidence)
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
	if stop := decision.NoRepair; stop != nil {
		question := Question(repairCase, stop.Reason)
		return repair.PlannerStop(data, stop.Reason, stop.Explanation, question), err
	}
	return repair.Decision{Data: data, Result: planning.Result{Outcome: planning.Repair}}, err
}
