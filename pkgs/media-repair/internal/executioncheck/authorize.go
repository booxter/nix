package executioncheck

import (
	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
)

type RejectionReason string

const (
	SupersededReplacement RejectionReason = "superseded_replacement"
	UnprovedReplacement   RejectionReason = "unproved_replacement"
)

type Authorization struct {
	Join         *decisionpolicy.AuthorizedJoin
	ManualImport *decisionpolicy.AuthorizedManualImport
	Remux        *decisionpolicy.AuthorizedRemux
	DVD          *decisionpolicy.AuthorizedDVDSelection
}

func Authorize(
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV3,
	policy decisionpolicy.RuntimePolicy,
) (Authorization, string, *decisionpolicy.ManualImportRuntimeAssessment, bool) {
	switch decision.Kind {
	case contracts.ActionJoinParts:
		validation := decisionpolicy.ValidateJoin(assembly, decision)
		if validation.Accepted() {
			return Authorization{Join: validation.Authorized}, "", nil, true
		}
		if len(validation.Rejections) != 0 {
			return Authorization{}, string(validation.Rejections[0].Reason), nil, false
		}
	case contracts.ActionManualImportFile:
		validation := decisionpolicy.ValidateManualImport(assembly, decision, policy)
		if validation.Accepted() {
			return Authorization{ManualImport: validation.Authorized}, "", validation.Runtime, true
		}
		if len(validation.Rejections) != 0 {
			return Authorization{}, string(validation.Rejections[0].Reason), validation.Runtime, false
		}
	case contracts.ActionRemuxBluray:
		validation := decisionpolicy.ValidateRemux(assembly, decision, policy)
		if validation.Accepted() {
			return Authorization{Remux: validation.Authorized}, "", validation.Runtime, true
		}
		if len(validation.Rejections) != 0 {
			return Authorization{}, string(validation.Rejections[0]), validation.Runtime, false
		}
	case contracts.ActionRemuxDVD:
		validation := decisionpolicy.ValidateDVD(assembly, decision, policy)
		if validation.Accepted() {
			return Authorization{DVD: validation.Authorized}, "", validation.Runtime, true
		}
		if len(validation.Rejections) != 0 {
			return Authorization{}, string(validation.Rejections[0]), validation.Runtime, false
		}
	}
	return Authorization{}, "", nil, false
}
