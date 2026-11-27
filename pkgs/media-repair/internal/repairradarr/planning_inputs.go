package repairradarr

import (
	"encoding/json"
	"slices"
	"strings"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

type planningInputs struct {
	Movie              *contracts.MovieClass            `json:"movie"`
	Download           contracts.Download               `json:"download"`
	Files              []contracts.FileElement          `json:"files"`
	Capabilities       []contracts.Capability           `json:"capabilities"`
	History            []contracts.HistoryElement       `json:"history"`
	ManualImports      []contracts.ManualImportElement  `json:"manual_imports"`
	ErrorMessage       string                           `json:"error_message"`
	StatusMessages     []contracts.StatusMessageElement `json:"status_messages"`
	StatusMessageCount int64                            `json:"status_message_count"`
}

func (adapter *Adapter) PlanningInputs(data json.RawMessage) (planning.Inputs, error) {
	repairCase, err := readPlanningCase(data)
	if err != nil {
		return planning.Inputs{}, err
	}
	// EncodeCase also checks that the saved case ID matches the evidence.
	if _, err := contracts.EncodeCase(repairCase); err != nil {
		return planning.Inputs{}, err
	}
	return planning.NewInputs(planningCaseInputs(repairCase))
}

func planningCaseInputs(repairCase contracts.RepairCaseV3) planningInputs {
	// Queue progress affects execution eligibility, not the movie or source
	// selection. Keep actual rejection diagnostics in the planning identity.
	failure := repairCase.Radarr.Failure
	inputs := planningInputs{
		Movie: repairCase.Radarr.Movie, Download: repairCase.Download,
		Files: slices.Clone(repairCase.Files), Capabilities: slices.Clone(repairCase.Capabilities),
		History: slices.Clone(repairCase.Radarr.History), ManualImports: slices.Clone(repairCase.Radarr.ManualImports),
		ErrorMessage: failure.ErrorMessage, StatusMessages: failure.StatusMessages,
		StatusMessageCount: failure.StatusMessageCount,
	}
	slices.SortFunc(inputs.Files, func(left, right contracts.FileElement) int {
		return strings.Compare(left.FileID, right.FileID)
	})
	slices.SortFunc(inputs.Capabilities, func(left, right contracts.Capability) int {
		return strings.Compare(left.CapabilityID, right.CapabilityID)
	})
	slices.SortFunc(inputs.History, func(left, right contracts.HistoryElement) int {
		return strings.Compare(left.EvidenceID, right.EvidenceID)
	})
	slices.SortFunc(inputs.ManualImports, func(left, right contracts.ManualImportElement) int {
		return strings.Compare(left.FileID, right.FileID)
	})
	inputs.Download.Labels = slices.Clone(inputs.Download.Labels)
	slices.Sort(inputs.Download.Labels)
	return inputs
}
