package casestore

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
	"github.com/booxter/nix-config/media-repair/internal/repairartifact"
	"github.com/booxter/nix-config/media-repair/internal/workerclient"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
)

func TestStoreRemuxStageAndPublishRequireExactEvidence(t *testing.T) {
	t.Parallel()
	store, prepared, exchange := preparedRemuxFixture(t)
	at := prepared.PreparedAt.Add(time.Minute)
	bad := exchange
	bad.Request.Clips = append([]workercontracts.BlurayRemuxSourceV1(nil), exchange.Request.Clips...)
	bad.Request.Clips[0].ExpectedFingerprint = exchange.Request.Playlist.ExpectedFingerprint
	if _, _, err := store.RecordRemuxStage(prepared.Authorization.CaseID, bad, at); err == nil {
		t.Fatal("accepted a different Blu-ray clip")
	}
	staged, changed, err := store.RecordRemuxStage(prepared.Authorization.CaseID, exchange, at)
	if err != nil || !changed || staged.State != RemuxStaged || staged.Artifact == nil {
		t.Fatalf("stage: changed = %t, state = %q, error = %v", changed, staged.State, err)
	}
	publish := remuxPublishResponse(t)
	publish.Success.ArtifactID = staged.Artifact.ID
	publish.Success.ArtifactFingerprint = staged.Artifact.Fingerprint
	publish.Success.PathComponents = []string{
		"Example.Movie", repairartifact.PublishedName(staged.Artifact.ID, ".mkv"),
	}
	badPublish := publish
	badSuccess := *publish.Success
	badSuccess.PathComponents = []string{"Example.Movie", repairartifact.PublishedName("other", ".mkv")}
	badPublish.Success = &badSuccess
	if _, _, err := store.RecordRemuxPublish(prepared.Authorization.CaseID, badPublish, at.Add(time.Minute)); err == nil {
		t.Fatal("accepted a different artifact destination")
	}
	published, changed, err := store.RecordRemuxPublish(prepared.Authorization.CaseID, publish, at.Add(time.Minute))
	if err != nil || !changed || published.State != RemuxPublished || published.Published == nil {
		t.Fatalf("publish: changed = %t, state = %q, error = %v", changed, published.State, err)
	}
	reloaded, found, err := store.GetRemuxExecution(prepared.Authorization.CaseID)
	if err != nil || !found || !reflect.DeepEqual(reloaded, published) {
		t.Fatalf("reload: found = %t, record = %#v, error = %v", found, reloaded, err)
	}
}

func TestPrepareRemuxRequiresStoredDecision(t *testing.T) {
	t.Parallel()
	joined, _ := joinExecutionAssembly(t)
	observation := joined.LocalSnapshot.Observation
	runtime := 120
	observation.Movie.RuntimeMinutes = &runtime
	playlistPath := "/downloads/Movie.Release/BDMV/PLAYLIST/00000.mpls"
	clipPath := "/downloads/Movie.Release/BDMV/STREAM/00000.m2ts"
	playlist := controller.InventoryFile{
		ID:             "file:playlist",
		PathComponents: []string{"Movie.Release", "BDMV", "PLAYLIST", "00000.mpls"},
		Fingerprint:    controller.FileFingerprint{Device: 1, Inode: 40, SizeBytes: 4_096, MTimeNS: 3},
	}
	clip := controller.InventoryFile{
		ID:             "file:clip",
		PathComponents: []string{"Movie.Release", "BDMV", "STREAM", "00000.m2ts"},
		Fingerprint:    controller.FileFingerprint{Device: 1, Inode: 41, SizeBytes: 8_390_000_000, MTimeNS: 3},
	}
	observation.Inventory.Files = append(observation.Inventory.Files, playlist, clip)
	observation.Inventory.Paths = append(observation.Inventory.Paths,
		controller.FilePathMapping{FileID: playlist.ID, AbsolutePath: playlistPath},
		controller.FilePathMapping{FileID: clip.ID, AbsolutePath: clipPath},
	)
	observation.Probes = append(observation.Probes,
		casebuilder.FileProbe{FileID: playlist.ID, Outcome: controller.UncollectedMediaProbe(controller.MediaProbeNotCandidate)},
		casebuilder.FileProbe{FileID: clip.ID, Outcome: controller.UncollectedMediaProbe(controller.MediaProbeNotCandidate)},
	)
	observation.BluRayPlaylists = []mkvmerge.Candidate{{
		PlaylistFileID: playlist.ID, ClipFileIDs: []controller.FileID{clip.ID},
		Details: mkvmerge.Playlist{
			DurationMS: 7_200_000, Chapters: 0, ClipPaths: []string{clipPath},
			Tracks: []mkvmerge.Track{{Kind: "video", Codec: "AVC/H.264/MPEG-4p10"}},
		},
	}}
	assembly, err := casebuilder.Assemble(observation)
	if err != nil {
		t.Fatal(err)
	}
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewRecord(assembly)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Put(record); err != nil {
		t.Fatal(err)
	}
	var capabilityID string
	for _, capability := range assembly.Request.Capabilities {
		if capability.Action == contracts.CapabilityActionRemuxBluray {
			capabilityID = capability.CapabilityID
		}
	}
	decisionData, err := os.ReadFile("../../contracts/v3/examples/repair-decision-remux-bluray.json")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := contracts.DecodeDecision(decisionData)
	if err != nil {
		t.Fatal(err)
	}
	decision.RemuxBluray.CaseID = assembly.Request.CaseID
	decision.RemuxBluray.CapabilityID = capabilityID
	validation := decisionpolicy.ValidateRemux(assembly, decision)
	if !validation.Accepted() {
		t.Fatalf("authorize fixture: %#v", validation)
	}
	if _, _, err := store.PrepareRemux(*validation.Authorized, observation.ObservedAt); err == nil {
		t.Fatal("prepared a remux before the decision was stored")
	}
	if _, _, err := store.PutPlanningDecision(assembly.Request.CaseID, decision, observation.ObservedAt); err != nil {
		t.Fatal(err)
	}
	prepared, changed, err := store.PrepareRemux(*validation.Authorized, observation.ObservedAt.Add(time.Minute))
	if err != nil || !changed || prepared.State != RemuxPrepared {
		t.Fatalf("prepare: changed = %t, state = %q, error = %v", changed, prepared.State, err)
	}
	wrong := *validation.Authorized
	wrong.CapabilityID = "other"
	if _, _, err := store.PrepareRemux(wrong, observation.ObservedAt.Add(2*time.Minute)); err == nil {
		t.Fatal("accepted authorization for a different capability")
	}
	requestData, err := os.ReadFile("../../worker/contracts/v1/examples/bluray-remux-request.json")
	if err != nil {
		t.Fatal(err)
	}
	request, err := workercontracts.DecodeBlurayRemuxRequest(requestData)
	if err != nil {
		t.Fatal(err)
	}
	request.CaseID = prepared.Authorization.CaseID
	request.CapabilityID = prepared.Authorization.CapabilityID
	request.ExecutionID = prepared.ExecutionID
	request.Playlist.PathComponents = playlist.PathComponents
	request.Playlist.ExpectedFingerprint = playlist.Fingerprint.Fingerprint()
	request.Playlist.SizeBytes = playlist.Fingerprint.SizeBytes
	request.Clips[0].PathComponents = clip.PathComponents
	request.Clips[0].ExpectedFingerprint = clip.Fingerprint.Fingerprint()
	request.Clips[0].SizeBytes = clip.Fingerprint.SizeBytes
	request.ExpectedDurationMS = prepared.Authorization.ExpectedDurationMS
	request.ExpectedChapterCount = prepared.Authorization.ExpectedChapters
	responseData, err := os.ReadFile("../../worker/contracts/v1/examples/bluray-remux-response-ok.json")
	if err != nil {
		t.Fatal(err)
	}
	response, err := workercontracts.DecodeBlurayRemuxResponse(responseData)
	if err != nil {
		t.Fatal(err)
	}
	response.Success.RequestID = request.RequestID
	staged, _, err := store.RecordRemuxStage(
		prepared.Authorization.CaseID,
		workerclient.BlurayRemuxExchange{Request: request, Response: response},
		observation.ObservedAt.Add(2*time.Minute),
	)
	if err != nil {
		t.Fatal(err)
	}
	publish := remuxPublishResponse(t)
	publish.Success.ArtifactID = staged.Artifact.ID
	publish.Success.ArtifactFingerprint = staged.Artifact.Fingerprint
	publish.Success.PathComponents = []string{
		"Movie.Release", repairartifact.PublishedName(staged.Artifact.ID, ".mkv"),
	}
	published, _, err := store.RecordRemuxPublish(
		prepared.Authorization.CaseID, publish, observation.ObservedAt.Add(3*time.Minute),
	)
	if err != nil {
		t.Fatal(err)
	}
	path := "/downloads/Movie.Release/" + published.Published.PathComponents[1]
	command, complete := controller.BuildRadarrPublishedFileImport(
		path, observation.Movie.ID, observation.Correlation.Radarr.DownloadID, observation.History,
	)
	if !complete {
		t.Fatal("fixture lacks Radarr grab metadata")
	}
	importRequest := JoinImportRequest{Command: command, HistoryIDBefore: 1}
	importPrepared, changed, err := store.PrepareRemuxImport(
		prepared.Authorization.CaseID, importRequest, observation.ObservedAt.Add(4*time.Minute),
	)
	if err != nil || !changed || importPrepared.State != RemuxImportPrepared {
		t.Fatalf("prepare import: changed = %t, state = %q, error = %v", changed, importPrepared.State, err)
	}
	requested, _, err := store.MarkRemuxImportRequested(
		prepared.Authorization.CaseID, 92, observation.ObservedAt.Add(5*time.Minute),
	)
	if err != nil || requested.State != RemuxImportRequested {
		t.Fatalf("request import: state = %q, error = %v", requested.State, err)
	}
	imported, _, err := store.MarkRemuxImported(
		prepared.Authorization.CaseID,
		testJoinedFileImport(importRequest, observation.ObservedAt.Add(6*time.Minute)),
		observation.ObservedAt.Add(7*time.Minute),
	)
	if err != nil || imported.State != RemuxImported || imported.Confirmation == nil {
		t.Fatalf("confirm import: state = %q, error = %v", imported.State, err)
	}
}

func TestStoreRemuxImportRecoversUncertainSubmission(t *testing.T) {
	t.Parallel()
	store, prepared, exchange := preparedRemuxFixture(t)
	at := prepared.PreparedAt.Add(time.Minute)
	staged, _, err := store.RecordRemuxStage(prepared.Authorization.CaseID, exchange, at)
	if err != nil {
		t.Fatal(err)
	}
	publish := remuxPublishResponse(t)
	publish.Success.ArtifactID = staged.Artifact.ID
	publish.Success.ArtifactFingerprint = staged.Artifact.Fingerprint
	publish.Success.PathComponents = []string{
		"Example.Movie", repairartifact.PublishedName(staged.Artifact.ID, ".mkv"),
	}
	published, _, err := store.RecordRemuxPublish(prepared.Authorization.CaseID, publish, at.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	request := testJoinImportRequest()
	request.Command.File.Path = "/downloads/Example.Movie/" + published.Published.PathComponents[1]
	// This fixture has no planned case. Seed the already validated import record
	// to test the recovery transition after an uncertain Radarr submission.
	published.State = RemuxImportPrepared
	published.Import = &JoinImport{
		Command: request.Command, HistoryIDBefore: request.HistoryIDBefore,
		PreparedAt: at.Add(2 * time.Minute),
	}
	published.UpdatedAt = published.Import.PreparedAt
	path, err := store.executionPath(prepared.Authorization.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.writeRemuxExecution(path, published); err != nil {
		t.Fatal(err)
	}
	confirmation := testJoinedFileImport(request, at.Add(3*time.Minute))
	imported, changed, err := store.MarkRemuxImported(
		prepared.Authorization.CaseID, confirmation, at.Add(4*time.Minute),
	)
	if err != nil || !changed || imported.State != RemuxImported ||
		imported.Import.CommandID != nil || imported.Confirmation == nil {
		t.Fatalf("recovery: changed = %t, state = %q, error = %v", changed, imported.State, err)
	}
	if _, _, err := store.MarkRemuxImportRequested(
		prepared.Authorization.CaseID, 42, at.Add(5*time.Minute),
	); err == nil {
		t.Fatal("submitted Radarr import again after confirmation")
	}
}

func preparedRemuxFixture(t *testing.T) (*Store, RemuxExecution, workerclient.BlurayRemuxExchange) {
	t.Helper()
	requestData, err := os.ReadFile("../../worker/contracts/v1/examples/bluray-remux-request.json")
	if err != nil {
		t.Fatal(err)
	}
	request, err := workercontracts.DecodeBlurayRemuxRequest(requestData)
	if err != nil {
		t.Fatal(err)
	}
	responseData, err := os.ReadFile("../../worker/contracts/v1/examples/bluray-remux-response-ok.json")
	if err != nil {
		t.Fatal(err)
	}
	response, err := workercontracts.DecodeBlurayRemuxResponse(responseData)
	if err != nil {
		t.Fatal(err)
	}
	playlistFingerprint := controller.FileFingerprint{Device: 1, Inode: 2, SizeBytes: request.Playlist.SizeBytes, MTimeNS: 3}
	clipFingerprint := controller.FileFingerprint{Device: 1, Inode: 4, SizeBytes: request.Clips[0].SizeBytes, MTimeNS: 3}
	authorized := decisionpolicy.AuthorizedRemux{
		CaseID: request.CaseID, CapabilityID: request.CapabilityID,
		Playlist:           decisionpolicy.AuthorizedRemuxFile{FileID: "playlist", Fingerprint: playlistFingerprint},
		Clips:              []decisionpolicy.AuthorizedRemuxFile{{FileID: "clip", Fingerprint: clipFingerprint}},
		SourceBytes:        request.Clips[0].SizeBytes,
		ExpectedDurationMS: request.ExpectedDurationMS,
		ExpectedChapters:   request.ExpectedChapterCount,
		ExpectedTracks:     []mkvmerge.Track{{Kind: "video", Codec: request.ExpectedTracks[0].Codec}},
	}
	id, err := RemuxExecutionID(authorized)
	if err != nil {
		t.Fatal(err)
	}
	request.ExecutionID = id
	request.Playlist.ExpectedFingerprint = playlistFingerprint.Fingerprint()
	request.Clips[0].ExpectedFingerprint = clipFingerprint.Fingerprint()
	response.Success.RequestID = request.RequestID
	store, err := New(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, time.September, 19, 12, 0, 0, 0, time.UTC)
	prepared := RemuxExecution{
		Version: RemuxExecutionVersionV1, ExecutionID: id,
		Authorization: authorized, State: RemuxPrepared,
		PreparedAt: at, UpdatedAt: at,
	}
	path, err := store.executionPath(authorized.CaseID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.writeRemuxExecution(path, prepared); err != nil {
		t.Fatal(err)
	}
	return store, prepared, workerclient.BlurayRemuxExchange{Request: request, Response: response}
}

func remuxPublishResponse(t *testing.T) workercontracts.BlurayPublishResponseV1 {
	t.Helper()
	data, err := os.ReadFile("../../worker/contracts/v1/examples/bluray-publish-response-ok.json")
	if err != nil {
		t.Fatal(err)
	}
	response, err := workercontracts.DecodeBlurayPublishResponse(data)
	if err != nil {
		t.Fatal(err)
	}
	return response
}
