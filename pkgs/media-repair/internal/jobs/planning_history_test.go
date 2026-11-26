package jobs

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

func TestPlanningHistorySurvivesRestartAndInputCycles(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "jobs.db")
	store, err := Open(path, testInputs)
	if err != nil {
		t.Fatal(err)
	}
	observation := Job{Service: Lidarr, QueueID: 1, SourceFingerprint: "case-a",
		Evidence: json.RawMessage(`{"files":"a","score":28.5}`)}
	job, err := store.Observe(ctx, observation)
	if err != nil {
		t.Fatal(err)
	}
	job.State, job.PlanningAttempts, job.Reason = Blocked, 1, "no repair"
	if err := store.FinishPlanning(ctx, job); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store = openStore(t, path)

	observation.SourceFingerprint = "case-a-new-score"
	observation.Evidence = json.RawMessage(`{"files":"a","score":39.5}`)
	job, err = store.Observe(ctx, observation)
	if err != nil || job.State != Blocked || job.PlanningAttempts != 1 || job.Reason != "no repair" {
		t.Fatalf("assessment noise reopened decision: %+v, %v", job, err)
	}
	observation.SourceFingerprint = "case-b"
	observation.Evidence = json.RawMessage(`{"files":"b"}`)
	job, err = store.Observe(ctx, observation)
	if err != nil || job.State != Observed || job.PlanningAttempts != 0 {
		t.Fatalf("new inputs did not allow planning: %+v, %v", job, err)
	}
	observation.SourceFingerprint = "case-a-again"
	observation.Evidence = json.RawMessage(`{"files":"a"}`)
	job, err = store.Observe(ctx, observation)
	if err != nil || job.State != Blocked || job.PlanningAttempts != 1 {
		t.Fatalf("returning inputs reopened decision: %+v, %v", job, err)
	}
	if err := store.RequestAction(ctx, job.ID, Reconsider, "try this mapping", 0, time.Now()); err != nil {
		t.Fatal(err)
	}
	job, err = store.Observe(ctx, observation)
	if err != nil || job.State != Observed || job.PlanningAttempts != 0 || job.Guidance != "try this mapping" {
		t.Fatalf("operator reconsideration suppressed: %+v, %v", job, err)
	}
}

func TestLegacyDecisionGetsPlanningBaseline(t *testing.T) {
	for _, changed := range []bool{false, true} {
		t.Run(map[bool]string{false: "assessment only", true: "new files"}[changed], func(t *testing.T) {
			ctx := context.Background()
			store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
			observation := Job{Service: Lidarr, QueueID: 1, SourceFingerprint: "old-case", Evidence: json.RawMessage(`{"files":"old"}`)}
			job, err := store.Observe(ctx, observation)
			if err != nil {
				t.Fatal(err)
			}
			job.State, job.PlanningAttempts = Blocked, 1
			if err := store.FinishPlanning(ctx, job); err != nil {
				t.Fatal(err)
			}
			// Reproduce a database written before planning identities existed.
			if err := store.db.Exec("UPDATE jobs SET planning_fingerprint = '' WHERE id = ?", job.ID).Error; err != nil {
				t.Fatal(err)
			}
			if err := store.db.Exec("DELETE FROM planning_results WHERE job_id = ?", job.ID).Error; err != nil {
				t.Fatal(err)
			}
			observation.SourceFingerprint = "new-case"
			want := Blocked
			if changed {
				observation.Evidence = json.RawMessage(`{"files":"new"}`)
				want = Observed
			}
			job, err = store.Observe(ctx, observation)
			if err != nil || job.State != want {
				t.Fatalf("legacy baseline: %+v, %v", job, err)
			}
			observation.Evidence = json.RawMessage(`{"files":"old"}`)
			job, err = store.Observe(ctx, observation)
			if err != nil || job.State != Blocked || job.PlanningAttempts != 1 {
				t.Fatalf("legacy decision forgotten: %+v, %v", job, err)
			}
		})
	}
}

func TestPlanningHistoryPreservesProviderBackoff(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	observation := Job{Service: Lidarr, QueueID: 1, SourceFingerprint: "case-a",
		Evidence: json.RawMessage(`{"files":"a"}`)}
	job, err := store.Observe(ctx, observation)
	if err != nil {
		t.Fatal(err)
	}
	retryAt := time.Now().UTC().Add(time.Hour)
	job.PlanningAttempts, job.RetryAt, job.Reason = 4, retryAt, "provider unavailable"
	if err := store.FinishPlanning(ctx, job); err != nil {
		t.Fatal(err)
	}
	observation.Evidence = json.RawMessage(`{"files":"b"}`)
	if _, err := store.Observe(ctx, observation); err != nil {
		t.Fatal(err)
	}
	observation.Evidence = json.RawMessage(`{"files":"a"}`)
	job, err = store.Observe(ctx, observation)
	if err != nil || job.State != Observed || job.PlanningAttempts != 4 || !job.RetryAt.Equal(retryAt) {
		t.Fatalf("input cycle bypassed provider backoff: %+v, %v", job, err)
	}
}

func TestAssessmentChangesPreserveReadyPlanEvidence(t *testing.T) {
	ctx := context.Background()
	store := openStore(t, filepath.Join(t.TempDir(), "jobs.db"))
	observation := Job{Service: Lidarr, QueueID: 1, SourceFingerprint: "planned-case",
		Evidence: json.RawMessage(`{"files":"a","score":28.5}`)}
	job, err := store.Observe(ctx, observation)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetPlan(ctx, job.ID, job.SourceFingerprint, json.RawMessage(`{}`), "", time.Now()); err != nil {
		t.Fatal(err)
	}
	observation.SourceFingerprint, observation.Evidence = "new-case", json.RawMessage(`{"files":"a","score":39.5}`)
	job, err = store.Observe(ctx, observation)
	if err != nil || job.State != Ready || job.SourceFingerprint != "planned-case" || string(job.Evidence) != `{"files":"a","score":28.5}` {
		t.Fatalf("ready plan evidence replaced: %+v, %v", job, err)
	}
	attempt, err := store.Start(ctx, job.ID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	attempt.State, attempt.Reason = Blocked, "current Lidarr evidence does not match the planned case"
	if err := store.UpdateAttempt(ctx, attempt); err != nil {
		t.Fatal(err)
	}
	job, err = store.Observe(ctx, observation)
	if err != nil || job.State != Blocked || job.Reason != attempt.Reason {
		t.Fatalf("authorization failure triggered replanning: %+v, %v", job, err)
	}
}
