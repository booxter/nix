package contracts

type RepairCaseV2 = RadarrRepairCaseVersion2

type DecisionAction string

const (
	CapabilityActionJoinParts        CapabilityAction = "join_parts_v1"
	CapabilityActionManualImportFile CapabilityAction = "manual_import_file_v1"
	CapabilityActionRemuxBluray      CapabilityAction = "remux_bluray_v1"
	CapabilityActionRemuxDVD         CapabilityAction = "remux_dvd_v1"

	ActionNoRepair         DecisionAction = "no_repair"
	ActionJoinParts        DecisionAction = "join_parts_v1"
	ActionManualImportFile DecisionAction = "manual_import_file_v1"
	ActionRemuxBluray      DecisionAction = "remux_bluray_v1"
)

type RepairDecisionV2 struct {
	Kind             DecisionAction
	NoRepair         *NoRepairDecision
	JoinParts        *JoinDecision
	ManualImportFile *ManualImportFileDecision
	RemuxBluray      *RemuxBlurayDecision
}

func (decision RepairDecisionV2) CaseID() string {
	switch decision.Kind {
	case ActionNoRepair:
		if decision.NoRepair != nil {
			return decision.NoRepair.CaseID
		}
	case ActionJoinParts:
		if decision.JoinParts != nil {
			return decision.JoinParts.CaseID
		}
	case ActionManualImportFile:
		if decision.ManualImportFile != nil {
			return decision.ManualImportFile.CaseID
		}
	case ActionRemuxBluray:
		if decision.RemuxBluray != nil {
			return decision.RemuxBluray.CaseID
		}
	}
	return ""
}
