package contracts

type RepairCaseV1 = RadarrRepairCaseVersion1

type DecisionAction string

const (
	ActionNoRepair  DecisionAction = DecisionAction(NoRepair)
	ActionJoinParts DecisionAction = DecisionAction(JoinPartsV1)
)

type RepairDecisionV1 struct {
	Kind      DecisionAction
	NoRepair  *NoRepairDecision
	JoinParts *JoinDecision
}

func (decision RepairDecisionV1) CaseID() string {
	switch decision.Kind {
	case ActionNoRepair:
		if decision.NoRepair != nil {
			return decision.NoRepair.CaseID
		}
	case ActionJoinParts:
		if decision.JoinParts != nil {
			return decision.JoinParts.CaseID
		}
	}
	return ""
}
