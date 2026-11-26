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
	UnsupportedAction     RejectionReason = "unsupported_action"
	RuntimeMismatch       RejectionReason = RejectionReason(decisionpolicy.RemuxRuntimeMismatch)
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
) (Authorization, RejectionReason) {
	switch decision.Kind {
	case contracts.ActionJoinParts:
		authorized, reason := decisionpolicy.ValidateJoin(assembly, decision)
		return Authorization{Join: authorized}, RejectionReason(reason)
	case contracts.ActionManualImportFile:
		authorized, reason := decisionpolicy.ValidateManualImport(assembly, decision, policy)
		return Authorization{ManualImport: authorized}, RejectionReason(reason)
	case contracts.ActionRemuxBluray:
		authorized, reason := decisionpolicy.ValidateRemux(assembly, decision, policy)
		return Authorization{Remux: authorized}, RejectionReason(reason)
	case contracts.ActionRemuxDVD:
		authorized, reason := decisionpolicy.ValidateDVD(assembly, decision, policy)
		return Authorization{DVD: authorized}, RejectionReason(reason)
	}
	return Authorization{}, UnsupportedAction
}
