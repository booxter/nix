package casestore

import (
	"fmt"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
)

type PlannedCase struct {
	Assembly casebuilder.Assembly
	Decision contracts.RepairDecisionV3
}

func (store *Store) GetPlannedCase(caseID string) (PlannedCase, error) {
	casePath, err := store.recordPath(caseID)
	if err != nil {
		return PlannedCase{}, err
	}
	caseRecord, found, err := readRecord(casePath)
	if err != nil {
		return PlannedCase{}, err
	}
	if !found {
		return PlannedCase{}, fmt.Errorf("case %q is not stored", caseID)
	}
	if caseRecord.CaseID != caseID {
		return PlannedCase{}, fmt.Errorf(
			"stored record has unexpected case ID %q",
			caseRecord.CaseID,
		)
	}

	planning, found, err := store.GetPlanningResult(caseID)
	if err != nil {
		return PlannedCase{}, err
	}
	if !found || !planning.HasDecision() {
		return PlannedCase{}, fmt.Errorf("case %q has no stored planning decision", caseID)
	}
	if planning.CaseID != caseID {
		return PlannedCase{}, fmt.Errorf(
			"stored planning result has unexpected case ID %q",
			planning.CaseID,
		)
	}

	decision, err := contracts.DecodeDecision(planning.Decision)
	if err != nil {
		return PlannedCase{}, fmt.Errorf("decode stored planning decision: %w", err)
	}
	request, err := contracts.DecodeCase(caseRecord.Request)
	if err != nil {
		return PlannedCase{}, fmt.Errorf("decode stored repair case: %w", err)
	}
	return PlannedCase{
		Assembly: casebuilder.Assembly{
			Request: request, EncodedRequest: cloneBytes(caseRecord.Request),
			LocalSnapshot: caseRecord.Snapshot,
		},
		Decision: decision,
	}, nil
}
