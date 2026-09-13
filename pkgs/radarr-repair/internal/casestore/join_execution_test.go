package casestore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
)

const joinArtifactFingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444"

func TestStoreJoinExecutionPublishesVerifiedArtifact(t *testing.T) {
	t.Parallel()

	store, authorized := newJoinExecutionStore(t)
	preparedAt := time.Date(2026, time.September, 13, 18, 0, 0, 0, time.UTC)
	prepared, changed, err := store.PrepareJoin(authorized, preparedAt)
	if err != nil || !changed || prepared.State != JoinPrepared ||
		!strings.HasPrefix(prepared.ExecutionID, "execution:") {
		t.Fatalf("prepare: changed = %t, record = %#v, error = %v", changed, prepared, err)
	}
	repeated, changed, err := store.PrepareJoin(authorized, preparedAt.Add(time.Minute))
	if err != nil || changed || !reflect.DeepEqual(repeated, prepared) {
		t.Fatalf("repeat prepare: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}

	request, response := successfulJoinStage(prepared, "request:stage:1")
	stagedAt := preparedAt.Add(time.Minute)
	staged, changed, err := store.RecordJoinStage(authorized, request, response, stagedAt)
	if err != nil || !changed || staged.State != JoinArtifactReady || staged.Artifact == nil ||
		staged.Artifact.ID != "artifact:join:01" || len(staged.Stage.Rejections) != 0 {
		t.Fatalf("record stage: changed = %t, record = %#v, error = %v", changed, staged, err)
	}
	request.RequestID = "request:stage:retry"
	response.Success.RequestID = request.RequestID
	repeated, changed, err = store.RecordJoinStage(
		authorized,
		request,
		response,
		stagedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, staged) {
		t.Fatalf("repeat stage: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}

	publish := publishSuccess("request:publish:1")
	publishedAt := stagedAt.Add(2 * time.Minute)
	published, changed, err := store.RecordJoinPublish(
		authorized.CaseID,
		publish,
		publishedAt,
	)
	if err != nil || !changed || published.State != JoinPublished ||
		!published.UpdatedAt.Equal(publishedAt) {
		t.Fatalf("publish: changed = %t, record = %#v, error = %v", changed, published, err)
	}
	publish.Success.RequestID = "request:publish:retry"
	repeated, changed, err = store.RecordJoinPublish(
		authorized.CaseID,
		publish,
		publishedAt.Add(time.Minute),
	)
	if err != nil || changed || !reflect.DeepEqual(repeated, published) {
		t.Fatalf("repeat publish: changed = %t, record = %#v, error = %v", changed, repeated, err)
	}
	if _, _, err := store.RecordJoinDiscard(
		authorized.CaseID,
		discardSuccess("request:discard:1"),
		publishedAt.Add(time.Minute),
	); err == nil {
		t.Fatal("published join was discarded")
	}

	stored, found, err := store.GetJoinExecution(authorized.CaseID)
	if err != nil || !found || !reflect.DeepEqual(stored, published) {
		t.Fatalf("stored execution: found = %t, record = %#v, error = %v", found, stored, err)
	}
}

func TestStoreJoinExecutionDiscardsRejectedArtifact(t *testing.T) {
	t.Parallel()

	store, authorized := newJoinExecutionStore(t)
	preparedAt := time.Date(2026, time.September, 13, 19, 0, 0, 0, time.UTC)
	prepared, _, err := store.PrepareJoin(authorized, preparedAt)
	if err != nil {
		t.Fatal(err)
	}
	request, response := successfulJoinStage(prepared, "request:stage:1")
	duration := authorized.ExpectedDurationMS + authorized.DurationToleranceMS + 1
	response.Success.Evidence.Format.DurationMS = &duration
	staged, changed, err := store.RecordJoinStage(
		authorized,
		request,
		response,
		preparedAt.Add(time.Minute),
	)
	if err != nil || !changed || staged.State != JoinDiscardPending ||
		staged.Artifact == nil || len(staged.Stage.Rejections) == 0 {
		t.Fatalf("record rejected stage: changed = %t, record = %#v, error = %v", changed, staged, err)
	}
	if _, _, err := store.RecordJoinPublish(
		authorized.CaseID,
		publishSuccess("request:publish:1"),
		preparedAt.Add(2*time.Minute),
	); err == nil {
		t.Fatal("rejected artifact was published")
	}
	discarded, changed, err := store.RecordJoinDiscard(
		authorized.CaseID,
		discardSuccess("request:discard:1"),
		preparedAt.Add(2*time.Minute),
	)
	if err != nil || !changed || discarded.State != JoinDiscarded {
		t.Fatalf("discard: changed = %t, record = %#v, error = %v", changed, discarded, err)
	}
}

func TestStoreJoinExecutionRecordsWorkerFailure(t *testing.T) {
	t.Parallel()

	store, authorized := newJoinExecutionStore(t)
	preparedAt := time.Date(2026, time.September, 13, 20, 0, 0, 0, time.UTC)
	prepared, _, err := store.PrepareJoin(authorized, preparedAt)
	if err != nil {
		t.Fatal(err)
	}
	request, _ := successfulJoinStage(prepared, "request:stage:1")
	response := workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.StageJoinFailureResponseV1{
			Operation: workercontracts.StageJoinV1, Reason: workercontracts.StageJoinJoinError,
			RequestID: request.RequestID, SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status: workercontracts.Failed,
		},
	}
	failed, changed, err := store.RecordJoinStage(
		authorized,
		request,
		response,
		preparedAt.Add(time.Minute),
	)
	if err != nil || !changed || failed.State != JoinFailed || failed.Failure == nil ||
		failed.Failure.Reason != string(workercontracts.StageJoinJoinError) {
		t.Fatalf("record failure: changed = %t, record = %#v, error = %v", changed, failed, err)
	}
}

func TestStoreJoinPreparationRequiresStoredAuthorization(t *testing.T) {
	t.Parallel()

	store, authorized := newJoinExecutionStore(t)
	authorized.OrderedParts[0].Fingerprint.Inode++
	if _, changed, err := store.PrepareJoin(
		authorized,
		time.Date(2026, time.September, 13, 21, 0, 0, 0, time.UTC),
	); err == nil || changed {
		t.Fatalf("changed authorization: changed = %t, error = %v", changed, err)
	}
}

func TestDecodeJoinExecutionRejectsInvalidRecord(t *testing.T) {
	t.Parallel()

	store, authorized := newJoinExecutionStore(t)
	prepared, _, err := store.PrepareJoin(
		authorized,
		time.Date(2026, time.September, 13, 22, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	data, err := EncodeJoinExecution(prepared)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeJoinExecution(data)
	if err != nil || !reflect.DeepEqual(decoded, prepared) {
		t.Fatalf("decode: record = %#v, error = %v", decoded, err)
	}

	invalid := prepared
	invalid.State = JoinPublished
	unchecked, err := json.Marshal(invalid)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeJoinExecution(unchecked); err == nil {
		t.Fatal("published record without an artifact was accepted")
	}
	withUnknown := append(data[:len(data)-1], []byte(`,"unknown":true}`)...)
	if _, err := DecodeJoinExecution(withUnknown); err == nil ||
		!strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unknown-field error = %v", err)
	}
}

func newJoinExecutionStore(t *testing.T) (*Store, decisionpolicy.AuthorizedJoin) {
	t.Helper()
	assembly, authorized := joinExecutionAssembly(t)
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewRecord(assembly)
	if err != nil {
		t.Fatal(err)
	}
	if created, err := store.Put(record); err != nil || !created {
		t.Fatalf("put case: created = %t, error = %v", created, err)
	}
	fileIDs := make([]string, len(authorized.OrderedParts))
	for position, part := range authorized.OrderedParts {
		fileIDs[position] = string(part.FileID)
	}
	decision := joinExecutionDecision(
		t,
		assembly.Request.CaseID,
		authorized.CapabilityID,
		fileIDs,
	)
	if _, changed, err := store.PutPlanningDecision(
		record.CaseID,
		decision,
		time.Date(2026, time.September, 13, 17, 0, 0, 0, time.UTC),
	); err != nil || !changed {
		t.Fatalf("put decision: changed = %t, error = %v", changed, err)
	}
	return store, authorized
}

func joinExecutionAssembly(t *testing.T) (casebuilder.Assembly, decisionpolicy.AuthorizedJoin) {
	t.Helper()
	first := joinExecutionFile("file:first", "Movie.CD1.mkv", 100, 0)
	second := joinExecutionFile("file:second", "Movie.CD2.mkv", 200, 1)
	downloadID := strings.Repeat("a", 40)
	observation := casebuilder.Observation{
		ObservedAt: time.Date(2026, time.September, 13, 16, 0, 0, 0, time.UTC),
		Correlation: controller.DownloadCorrelation{
			DownloadRoot: "/downloads/Movie.Release",
			Radarr: controller.RadarrQueueRecord{
				ID: 71, Protocol: "torrent", Title: "Movie", Status: "completed",
				TrackedDownloadStatus: "warning", TrackedDownloadState: "importPending",
				DownloadID: downloadID, OutputPath: "/downloads/Movie.Release",
			},
			Transmission: controller.TransmissionTorrent{
				Hash: downloadID, Name: "Movie.Release", TotalSizeBytes: 300,
				DownloadDirectory: "/downloads",
				Files: []controller.TransmissionFile{
					{Index: 0, Name: "Movie.Release/Movie.CD1.mkv", LengthBytes: 100, BytesCompleted: 100, Wanted: true},
					{Index: 1, Name: "Movie.Release/Movie.CD2.mkv", LengthBytes: 200, BytesCompleted: 200, Wanted: true},
				},
				Labels: []string{},
			},
		},
		History:       []controller.RadarrHistoryEvent{},
		ManualImports: []controller.RadarrManualImport{},
		Inventory: controller.FileInventory{
			Files: []controller.InventoryFile{first, second},
			Paths: []controller.FilePathMapping{
				{FileID: first.ID, AbsolutePath: "/downloads/Movie.Release/Movie.CD1.mkv"},
				{FileID: second.ID, AbsolutePath: "/downloads/Movie.Release/Movie.CD2.mkv"},
			},
		},
		Probes: []casebuilder.FileProbe{
			{FileID: first.ID, Outcome: controller.SuccessfulMediaProbe(joinExecutionProbe(10_000, 100))},
			{FileID: second.ID, Outcome: controller.SuccessfulMediaProbe(joinExecutionProbe(20_000, 200))},
		},
	}
	assembly, err := casebuilder.Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	var capabilityID string
	for _, capability := range assembly.Request.Capabilities {
		if capability.Action == contracts.CapabilityActionJoinParts {
			capabilityID = capability.CapabilityID
			break
		}
	}
	if capabilityID == "" {
		t.Fatal("assembly has no join capability")
	}
	decision := joinExecutionDecision(
		t,
		assembly.Request.CaseID,
		capabilityID,
		[]string{"file:first", "file:second"},
	)
	validation := decisionpolicy.ValidateJoin(assembly, decision)
	if !validation.Accepted() || validation.Authorized == nil {
		t.Fatalf("join validation = %#v", validation)
	}
	return assembly, *validation.Authorized
}

func joinExecutionDecision(
	t *testing.T,
	caseID string,
	capabilityID string,
	fileIDs []string,
) contracts.RepairDecisionV1 {
	t.Helper()
	data, err := os.ReadFile("../../contracts/v1/examples/repair-decision-join.json")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := contracts.DecodeDecision(data)
	if err != nil {
		t.Fatal(err)
	}
	decision.JoinParts.CaseID = caseID
	decision.JoinParts.CapabilityID = capabilityID
	decision.JoinParts.OrderedFileIDS = append([]string(nil), fileIDs...)
	return decision
}

func joinExecutionFile(
	id controller.FileID,
	name string,
	size int64,
	index int,
) controller.InventoryFile {
	return controller.InventoryFile{
		ID: id, PathComponents: []string{name},
		Fingerprint: controller.FileFingerprint{
			Device: 1, Inode: uint64(index + 2), SizeBytes: size, MTimeNS: 3,
		},
		TorrentFile: &controller.TorrentFileReference{
			Index: index, LengthBytes: size, BytesCompleted: size, Wanted: true,
		},
	}
}

func joinExecutionProbe(durationMS int64, size int64) controller.ProbeEvidence {
	kind := controller.ProbeStreamVideo
	codec := "h264"
	timeBase := controller.Rational{Numerator: 1, Denominator: 1_000}
	frameRate := controller.Rational{Numerator: 24, Denominator: 1}
	width := int64(1_920)
	height := int64(1_080)
	pixelFormat := "yuv420p"
	no := false
	yes := true
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska"}, DurationMS: &durationMS, SizeBytes: &size,
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &kind, CodecName: &codec, TimeBase: &timeBase,
			DurationMS: &durationMS, Width: &width, Height: &height,
			PixelFormat: &pixelFormat, AverageRate: &frameRate,
			Disposition: &controller.ProbeDisposition{
				Default: &yes, Forced: &no, HearingImpaired: &no, VisualImpaired: &no,
			},
			Tags: []controller.ProbeTag{},
		}},
		Programs: []controller.ProbeProgram{}, Chapters: []controller.ProbeChapter{},
	}
}

func successfulJoinStage(
	execution JoinExecution,
	requestID string,
) (workercontracts.StageJoinRequestV1, workercontracts.StageJoinResponseV1) {
	authorized := execution.Authorization
	parts := make([]workercontracts.StageJoinPartV1, len(authorized.OrderedParts))
	for position, part := range authorized.OrderedParts {
		parts[position] = workercontracts.StageJoinPartV1{
			FileID: string(part.FileID), PathComponents: []string{"Movie.Release", filepath.Base(string(part.FileID)) + ".mkv"},
			ExpectedFingerprint: part.Fingerprint.Fingerprint(),
		}
	}
	request := workercontracts.StageJoinRequestV1{
		CapabilityID: authorized.CapabilityID, CaseID: authorized.CaseID,
		DurationToleranceMS: authorized.DurationToleranceMS, ExecutionID: execution.ExecutionID,
		ExpectedDurationMS: authorized.ExpectedDurationMS, ExpectedSourceBytes: authorized.SourceBytes,
		ExpectedStreamCount: int64(len(authorized.ExpectedStreamLayout.Streams)),
		Operation:           workercontracts.StageJoinV1, OutputContainer: workercontracts.OutputContainerMKV,
		Parts: parts, RequestID: requestID, RootID: "root:downloads",
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
	}
	evidence := joinExecutionProbe(authorized.ExpectedDurationMS, authorized.SourceBytes-1)
	response := workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.StageJoinSuccessResponseV1{
			ArtifactFingerprint: joinArtifactFingerprint, ArtifactID: "artifact:join:01",
			Evidence: mediaevidence.FromProbe(evidence), Operation: workercontracts.StageJoinV1,
			RequestID: requestID, SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			SizeBytes: authorized.SourceBytes - 1, Status: workercontracts.Ok,
		},
	}
	return request, response
}

func publishSuccess(requestID string) workercontracts.PublishResponseV1 {
	return workercontracts.PublishResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.PublishSuccessResponseV1{
			ArtifactFingerprint: joinArtifactFingerprint, ArtifactID: "artifact:join:01",
			Operation:      workercontracts.PublishV1,
			PathComponents: []string{"Movie.Release", "radarr-repair-join.mkv"},
			RequestID:      requestID, RootID: "root:downloads",
			SchemaVersion: workercontracts.RadarrRepairWorkerV1, Status: workercontracts.Ok,
		},
	}
}

func discardSuccess(requestID string) workercontracts.DiscardResponseV1 {
	return workercontracts.DiscardResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.DiscardSuccessResponseV1{
			ArtifactFingerprint: joinArtifactFingerprint, ArtifactID: "artifact:join:01",
			Operation: workercontracts.DiscardV1, RequestID: requestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1, Status: workercontracts.Ok,
		},
	}
}
