package plannerclient

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/planning"
)

func TestFirstPlanAcceptsOperatorGuidance(t *testing.T) {
	repairCase := fixtureCase(t)
	decision := fixtureDecisionData(t, repairCase.CaseID)
	guidance := "Accept the selected runtime tolerance."

	socket := serveUnix(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var input struct {
			JobID                      int64           `json:"job_id"`
			PriorDecision              json.RawMessage `json:"prior_decision"`
			Guidance                   string          `json:"operator_guidance"`
			MaximumRuntimeDifferenceMS int64           `json:"maximum_runtime_difference_ms"`
		}
		if err := json.NewDecoder(request.Body).Decode(&input); err != nil {
			http.Error(writer, "invalid request", http.StatusBadRequest)
			return
		}
		if input.JobID != 42 || input.Guidance != guidance || input.MaximumRuntimeDifferenceMS != 1_800_000 || len(input.PriorDecision) != 0 {
			http.Error(writer, "missing first-plan guidance", http.StatusUnprocessableEntity)
			return
		}
		writeJSON(writer, decision)
	}))
	client := testClient(t, socket, time.Second)

	_, err := client.PlanRadarr(context.Background(), repairCase, planning.Options{
		JobID:  42,
		Answer: planning.Answer{Guidance: guidance, RuntimeToleranceMS: 1_800_000},
	})
	if err != nil {
		t.Fatalf("first plan with operator guidance failed: %v", err)
	}
}
