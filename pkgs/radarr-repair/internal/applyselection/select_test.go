package applyselection

import (
	"reflect"
	"strings"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func TestSelectPermittedRepairsInObservedOrder(t *testing.T) {
	t.Parallel()

	planned := []casestore.PlannedCase{
		testPlannedCase("no-repair", contracts.ActionNoRepair),
		testPlannedCase("manual-first", contracts.ActionManualImportFile),
		testPlannedCase("join", contracts.ActionJoinParts),
		testPlannedCase("manual-second", contracts.ActionManualImportFile),
	}
	selected, err := Select(planned, Policy{
		AllowedActions: map[contracts.DecisionAction]bool{
			contracts.ActionManualImportFile: true,
		},
		AllowedDownloadClients: map[controller.DownloadClient]bool{
			controller.DownloadClientTransmission: true,
		},
		Limit: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := caseIDs(selected), []string{"manual-first", "manual-second"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("selected cases = %v, want %v", got, want)
	}
}

func TestSelectStopsAtRepairLimit(t *testing.T) {
	t.Parallel()

	planned := []casestore.PlannedCase{
		testPlannedCase("join-first", contracts.ActionJoinParts),
		testPlannedCase("manual", contracts.ActionManualImportFile),
		testPlannedCase("join-second", contracts.ActionJoinParts),
	}
	selected, err := Select(planned, Policy{
		AllowedActions: map[contracts.DecisionAction]bool{
			contracts.ActionJoinParts:        true,
			contracts.ActionManualImportFile: true,
		},
		AllowedDownloadClients: map[controller.DownloadClient]bool{
			controller.DownloadClientTransmission: true,
		},
		Limit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := caseIDs(selected), []string{"join-first"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("selected cases = %v, want %v", got, want)
	}
}

func TestSelectsNoRepairsWithEmptyAllowlist(t *testing.T) {
	t.Parallel()

	selected, err := Select(
		[]casestore.PlannedCase{
			testPlannedCase("join", contracts.ActionJoinParts),
			testPlannedCase("manual", contracts.ActionManualImportFile),
		},
		Policy{Limit: 1},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(selected) != 0 {
		t.Fatalf("selected cases = %v", caseIDs(selected))
	}
}

func TestBluRayDecisionRequiresExplicitAllowlist(t *testing.T) {
	t.Parallel()
	candidate := testPlannedCase("disc", contracts.ActionRemuxBluray)
	policy := Policy{
		AllowedActions: map[contracts.DecisionAction]bool{
			contracts.ActionJoinParts: true,
		},
		AllowedDownloadClients: map[controller.DownloadClient]bool{
			controller.DownloadClientTransmission: true,
		},
		Limit: 1,
	}
	selected, err := Select([]casestore.PlannedCase{candidate}, policy)
	if err != nil {
		t.Fatal(err)
	}
	if len(selected) != 0 {
		t.Fatalf("selected an unsupported Blu-ray apply: %v", caseIDs(selected))
	}
	policy.AllowedActions[contracts.ActionRemuxBluray] = true
	selected, err = Select([]casestore.PlannedCase{candidate}, policy)
	if err != nil || len(selected) != 1 {
		t.Fatalf("allowed Blu-ray case: selected = %v, error = %v", caseIDs(selected), err)
	}
}

func TestDVDDecisionRequiresExplicitAllowlist(t *testing.T) {
	t.Parallel()
	candidate := testPlannedCase("dvd", contracts.ActionRemuxDVD)
	policy := Policy{
		AllowedActions: map[contracts.DecisionAction]bool{contracts.ActionRemuxBluray: true},
		AllowedDownloadClients: map[controller.DownloadClient]bool{
			controller.DownloadClientTransmission: true,
		},
		Limit: 1,
	}
	selected, err := Select([]casestore.PlannedCase{candidate}, policy)
	if err != nil || len(selected) != 0 {
		t.Fatalf("DVD selected without allowlist: %v, error = %v", caseIDs(selected), err)
	}
	policy.AllowedActions[contracts.ActionRemuxDVD] = true
	selected, err = Select([]casestore.PlannedCase{candidate}, policy)
	if err != nil || len(selected) != 1 {
		t.Fatalf("allowed DVD case: %v, error = %v", caseIDs(selected), err)
	}
}

func TestSelectRejectsCaseFromUnallowedDownloadClient(t *testing.T) {
	t.Parallel()

	candidate := testPlannedCase("sab", contracts.ActionManualImportFile)
	candidate.Assembly.LocalSnapshot.Observation.Correlation.Download.Client =
		controller.DownloadClientSABnzbd
	selected, err := Select([]casestore.PlannedCase{candidate}, Policy{
		AllowedActions: map[contracts.DecisionAction]bool{
			contracts.ActionManualImportFile: true,
		},
		AllowedDownloadClients: map[controller.DownloadClient]bool{
			controller.DownloadClientTransmission: true,
		},
		Limit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(selected) != 0 {
		t.Fatalf("selected cases = %v", caseIDs(selected))
	}
}

func TestSelectRejectsInvalidPolicy(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		policy Policy
		want   string
	}{
		{name: "zero limit", policy: Policy{}, want: "limit must be positive"},
		{
			name: "no repair allowed",
			policy: Policy{
				AllowedActions: map[contracts.DecisionAction]bool{
					contracts.ActionNoRepair: true,
				},
				Limit: 1,
			},
			want: "cannot be allowed",
		},
		{
			name: "unknown action allowed",
			policy: Policy{
				AllowedActions: map[contracts.DecisionAction]bool{"erase": true},
				Limit:          1,
			},
			want: "cannot be allowed",
		},
		{
			name: "unknown download client allowed",
			policy: Policy{
				AllowedDownloadClients: map[controller.DownloadClient]bool{"other": true},
				Limit:                  1,
			},
			want: "cannot be allowed",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			_, err := Select(nil, test.policy)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func TestSelectRejectsUnknownPlannedAction(t *testing.T) {
	t.Parallel()

	_, err := Select(
		[]casestore.PlannedCase{testPlannedCase("unknown", "erase")},
		Policy{Limit: 1},
	)
	if err == nil || !strings.Contains(err.Error(), `unknown action "erase"`) {
		t.Fatalf("error = %v", err)
	}
}

func testPlannedCase(caseID string, action contracts.DecisionAction) casestore.PlannedCase {
	return casestore.PlannedCase{
		Assembly: casebuilder.Assembly{
			Request: contracts.RepairCaseV2{CaseID: caseID},
			LocalSnapshot: casebuilder.LocalSnapshot{Observation: casebuilder.Observation{
				Correlation: controller.DownloadCorrelation{Download: controller.Download{
					Client: controller.DownloadClientTransmission,
				}},
			}},
		},
		Decision: contracts.RepairDecisionV2{Kind: action},
	}
}

func caseIDs(planned []casestore.PlannedCase) []string {
	caseIDs := make([]string, len(planned))
	for index, candidate := range planned {
		caseIDs[index] = candidate.Assembly.Request.CaseID
	}
	return caseIDs
}
