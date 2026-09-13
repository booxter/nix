package joinstate

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
)

func TestStorePersistsJoinLifecycle(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	request := stageRequest(t)
	preparedAt := time.Date(
		2026,
		time.September,
		13,
		16,
		0,
		0,
		0,
		time.FixedZone("test", -4*60*60),
	)
	prepared, changed, err := store.Prepare(request, preparedAt)
	if err != nil || !changed {
		t.Fatalf("prepare: changed = %t, error = %v", changed, err)
	}
	if prepared.State != Prepared || prepared.Staged != nil ||
		prepared.PreparedAt.Location() != time.UTC ||
		prepared.UpdatedAt != prepared.PreparedAt ||
		!strings.HasPrefix(prepared.ArtifactID, "artifact:") {
		t.Fatalf("prepared execution = %#v", prepared)
	}

	retry := request
	retry.RequestID = "request:join:retry"
	repeated, changed, err := store.Prepare(retry, preparedAt.Add(time.Hour))
	if err != nil || changed || !reflect.DeepEqual(repeated, prepared) {
		t.Fatalf(
			"repeat preparation: changed = %t, record = %#v, error = %v",
			changed,
			repeated,
			err,
		)
	}

	reopened, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	stored, found, err := reopened.Get(request.ExecutionID)
	if err != nil || !found || !reflect.DeepEqual(stored, prepared) {
		t.Fatalf("reopen: found = %t, record = %#v, error = %v", found, stored, err)
	}
	byArtifact, found, err := reopened.FindByArtifactID(prepared.ArtifactID)
	if err != nil || !found || !reflect.DeepEqual(byArtifact, prepared) {
		t.Fatalf(
			"artifact lookup: found = %t, record = %#v, error = %v",
			found,
			byArtifact,
			err,
		)
	}

	staged := stagedArtifact(t)
	stagedAt := prepared.PreparedAt.Add(time.Minute)
	if _, changed, err := reopened.MarkStaged(
		request.ExecutionID,
		"artifact:different",
		staged,
		stagedAt,
	); err == nil || changed {
		t.Fatalf("mismatched artifact: changed = %t, error = %v", changed, err)
	}
	stagedExecution, changed, err := reopened.MarkStaged(
		request.ExecutionID,
		prepared.ArtifactID,
		staged,
		stagedAt,
	)
	if err != nil || !changed || stagedExecution.State != Staged ||
		stagedExecution.Staged == nil || !reflect.DeepEqual(*stagedExecution.Staged, staged) {
		t.Fatalf("mark staged: changed = %t, record = %#v, error = %v", changed, stagedExecution, err)
	}
	repeated, changed, err = reopened.MarkStaged(
		request.ExecutionID,
		prepared.ArtifactID,
		staged,
		stagedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, stagedExecution) {
		t.Fatalf("repeat stage: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, changed, err := reopened.MarkStageFailed(
		request.ExecutionID,
		workercontracts.StageJoinJoinError,
		stagedAt.Add(time.Minute),
	); err == nil || changed {
		t.Fatalf("fail staged execution: changed = %t, error = %v", changed, err)
	}

	published := PublishedArtifact{
		RootID:         "root:downloads",
		PathComponents: []string{"Movie.Release", "radarr-repair-join.mkv"},
	}
	publishedAt := stagedAt.Add(2 * time.Minute)
	publishedExecution, changed, err := reopened.MarkPublished(
		request.ExecutionID,
		prepared.ArtifactID,
		staged.Fingerprint,
		published,
		publishedAt,
	)
	if err != nil || !changed || publishedExecution.State != Published ||
		publishedExecution.Published == nil ||
		!reflect.DeepEqual(*publishedExecution.Published, published) {
		t.Fatalf(
			"mark published: changed = %t, record = %#v, error = %v",
			changed,
			publishedExecution,
			err,
		)
	}
	repeated, changed, err = reopened.MarkPublished(
		request.ExecutionID,
		prepared.ArtifactID,
		staged.Fingerprint,
		published,
		publishedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, publishedExecution) {
		t.Fatalf("repeat publish: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, changed, err := reopened.MarkDiscarded(
		request.ExecutionID,
		prepared.ArtifactID,
		staged.Fingerprint,
		publishedAt.Add(time.Minute),
	); err == nil || changed {
		t.Fatalf("discard published artifact: changed = %t, error = %v", changed, err)
	}

	assertPrivateMode(t, root, 0o700)
	assertPrivateMode(t, filepath.Join(root, executionsDirectoryName), 0o700)
	entries, err := os.ReadDir(filepath.Join(root, executionsDirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("execution files = %d, want 1", len(entries))
	}
	assertPrivateMode(
		t,
		filepath.Join(root, executionsDirectoryName, entries[0].Name()),
		0o600,
	)
}

func TestStoreRejectsExecutionSpecificationConflict(t *testing.T) {
	t.Parallel()

	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	request := stageRequest(t)
	preparedAt := time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC)
	original, changed, err := store.Prepare(request, preparedAt)
	if err != nil || !changed {
		t.Fatalf("prepare: changed = %t, error = %v", changed, err)
	}
	request.ExpectedDurationMS++
	_, changed, err = store.Prepare(request, preparedAt.Add(time.Minute))
	var conflict *ConflictError
	if !errors.As(err, &conflict) || changed || conflict.ExecutionID != request.ExecutionID {
		t.Fatalf("conflict: changed = %t, conflict = %#v, error = %v", changed, conflict, err)
	}
	stored, found, err := store.Get(request.ExecutionID)
	if err != nil || !found || !reflect.DeepEqual(stored, original) {
		t.Fatalf("stored after conflict: found = %t, record = %#v, error = %v", found, stored, err)
	}
}

func TestStorePersistsDiscardAndFailureOutcomes(t *testing.T) {
	t.Parallel()

	preparedAt := time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC)
	t.Run("discarded", func(t *testing.T) {
		request := stageRequest(t)
		store, err := New(filepath.Join(t.TempDir(), "state"))
		if err != nil {
			t.Fatal(err)
		}
		prepared, _, err := store.Prepare(request, preparedAt)
		if err != nil {
			t.Fatal(err)
		}
		staged := stagedArtifact(t)
		if _, _, err := store.MarkStaged(
			request.ExecutionID,
			prepared.ArtifactID,
			staged,
			preparedAt.Add(time.Minute),
		); err != nil {
			t.Fatal(err)
		}
		discarded, changed, err := store.MarkDiscarded(
			request.ExecutionID,
			prepared.ArtifactID,
			staged.Fingerprint,
			preparedAt.Add(2*time.Minute),
		)
		if err != nil || !changed || discarded.State != Discarded || discarded.Staged == nil {
			t.Fatalf("discard: changed = %t, record = %#v, error = %v", changed, discarded, err)
		}
		repeated, changed, err := store.MarkDiscarded(
			request.ExecutionID,
			prepared.ArtifactID,
			staged.Fingerprint,
			preparedAt.Add(3*time.Minute),
		)
		if err != nil || changed || !reflect.DeepEqual(repeated, discarded) {
			t.Fatalf("repeat discard: changed = %t, record = %#v, error = %v", changed, repeated, err)
		}
	})

	t.Run("failed", func(t *testing.T) {
		request := stageRequest(t)
		store, err := New(filepath.Join(t.TempDir(), "state"))
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := store.Prepare(request, preparedAt); err != nil {
			t.Fatal(err)
		}
		failed, changed, err := store.MarkStageFailed(
			request.ExecutionID,
			workercontracts.StageJoinInsufficientSpace,
			preparedAt.Add(time.Minute),
		)
		if err != nil || !changed || failed.State != Failed || failed.Failure == nil ||
			failed.Failure.Reason != workercontracts.StageJoinInsufficientSpace {
			t.Fatalf("fail: changed = %t, record = %#v, error = %v", changed, failed, err)
		}
		repeated, changed, err := store.MarkStageFailed(
			request.ExecutionID,
			workercontracts.StageJoinInsufficientSpace,
			preparedAt.Add(2*time.Minute),
		)
		if err != nil || changed || !reflect.DeepEqual(repeated, failed) {
			t.Fatalf("repeat failure: changed = %t, record = %#v, error = %v", changed, repeated, err)
		}
		if _, changed, err := store.MarkStageFailed(
			request.ExecutionID,
			workercontracts.StageJoinJoinError,
			preparedAt.Add(2*time.Minute),
		); err == nil || changed {
			t.Fatalf("replace failure: changed = %t, error = %v", changed, err)
		}
	})
}

func TestStoreRejectsCorruptExecution(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	request := stageRequest(t)
	if _, _, err := store.Prepare(
		request,
		time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC),
	); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(root, executionsDirectoryName))
	if err != nil || len(entries) != 1 {
		t.Fatalf("read execution directory: entries = %d, error = %v", len(entries), err)
	}
	path := filepath.Join(root, executionsDirectoryName, entries[0].Name())
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	document["unknown"] = true
	corrupt, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, corrupt, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, found, err := store.Get(request.ExecutionID); err == nil || found ||
		!strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("corrupt execution: found = %t, error = %v", found, err)
	}
	if _, found, err := store.FindByArtifactID(
		"artifact:0000000000000000000000000000000000000000000000000000000000000000",
	); err == nil || found || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("corrupt artifact lookup: found = %t, error = %v", found, err)
	}
}

func TestStoreArtifactLookupHandlesMissingAndTemporaryRecords(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	request := stageRequest(t)
	prepared, _, err := store.Prepare(
		request,
		time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(root, executionsDirectoryName, ".state-abandoned.tmp"),
		[]byte("incomplete"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	foundExecution, found, err := store.FindByArtifactID(prepared.ArtifactID)
	if err != nil || !found || !reflect.DeepEqual(foundExecution, prepared) {
		t.Fatalf(
			"artifact lookup: found = %t, record = %#v, error = %v",
			found,
			foundExecution,
			err,
		)
	}
	missingID := "artifact:0000000000000000000000000000000000000000000000000000000000000000"
	if _, found, err := store.FindByArtifactID(missingID); err != nil || found {
		t.Fatalf("missing artifact lookup: found = %t, error = %v", found, err)
	}
	if _, found, err := store.FindByArtifactID("artifact:not-a-digest"); err == nil || found {
		t.Fatalf("invalid artifact lookup: found = %t, error = %v", found, err)
	}
}

func TestStoreArtifactLookupRejectsDuplicateRecord(t *testing.T) {
	t.Parallel()

	root := filepath.Join(t.TempDir(), "state")
	store, err := New(root)
	if err != nil {
		t.Fatal(err)
	}
	request := stageRequest(t)
	prepared, _, err := store.Prepare(
		request,
		time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(root, executionsDirectoryName))
	if err != nil || len(entries) != 1 {
		t.Fatalf("read execution directory: entries = %d, error = %v", len(entries), err)
	}
	original := filepath.Join(root, executionsDirectoryName, entries[0].Name())
	data, err := os.ReadFile(original)
	if err != nil {
		t.Fatal(err)
	}
	duplicate := filepath.Join(
		root,
		executionsDirectoryName,
		strings.Repeat("0", sha256.Size*2)+".json",
	)
	if err := os.WriteFile(duplicate, data, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, found, err := store.FindByArtifactID(prepared.ArtifactID); err == nil || found {
		t.Fatalf("duplicate artifact lookup: found = %t, error = %v", found, err)
	}
}

func stageRequest(t *testing.T) workercontracts.StageJoinRequestV1 {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/join-stage-request.json")
	if err != nil {
		t.Fatal(err)
	}
	request, err := workercontracts.DecodeStageJoinRequest(data)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

func stagedArtifact(t *testing.T) StagedArtifact {
	t.Helper()
	data, err := os.ReadFile("../contracts/v1/examples/join-stage-response-ok.json")
	if err != nil {
		t.Fatal(err)
	}
	response, err := workercontracts.DecodeStageJoinResponse(data)
	if err != nil {
		t.Fatal(err)
	}
	if response.Success == nil {
		t.Fatal("stage response fixture is not successful")
	}
	return StagedArtifact{
		Fingerprint: response.Success.ArtifactFingerprint,
		SizeBytes:   response.Success.SizeBytes,
		Evidence:    response.Success.Evidence,
	}
}

func assertPrivateMode(t *testing.T, path string, expected os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != expected {
		t.Fatalf("%s mode = %#o, want %#o", path, info.Mode().Perm(), expected)
	}
}
