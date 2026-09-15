package repairexecution

import (
	"context"
	"errors"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/executioncheck"
)

func TestExecutorResumesStoredManualImport(t *testing.T) {
	t.Parallel()

	assembly, decision, authorized := manualRecoveryScenario(t)
	store := &fakeExecutionStore{
		manualFound: true,
		manual: casestore.ManualImportExecution{
			CaseID:       authorized.CaseID,
			CapabilityID: authorized.CapabilityID,
			FileID:       authorized.FileID,
			State:        casestore.ManualImportRequested,
		},
	}
	checker := &fakeChecker{}
	manual := &fakeManualImporter{execution: casestore.ManualImportExecution{
		State: casestore.ManualImportImported,
	}}
	executor := testExecutorWithStore(
		t, store, checker, manual, &fakeJoinExecutor{}, &fakeJoinedFileImporter{},
	)

	result, err := executor.Execute(context.Background(), assembly, decision)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Resumed || result.ManualImport == nil ||
		result.ManualImport.State != casestore.ManualImportImported ||
		checker.calls != 0 || manual.calls != 1 {
		t.Fatalf(
			"result = %#v, checker calls = %d, manual calls = %d",
			result,
			checker.calls,
			manual.calls,
		)
	}
}

func TestExecutorResumesStoredJoin(t *testing.T) {
	t.Parallel()

	assembly, decision, authorized := joinRecoveryScenario(t)
	tests := []struct {
		name          string
		state         casestore.JoinExecutionState
		joinResult    casestore.JoinExecutionState
		want          casestore.JoinExecutionState
		wantJoinCalls int
		wantImports   int
	}{
		{"prepared", casestore.JoinPrepared, casestore.JoinPublished, casestore.JoinImported, 1, 1},
		{"artifact ready", casestore.JoinArtifactReady, casestore.JoinPublished, casestore.JoinImported, 1, 1},
		{"discard pending", casestore.JoinDiscardPending, casestore.JoinDiscarded, casestore.JoinDiscarded, 1, 0},
		{"published", casestore.JoinPublished, "", casestore.JoinImported, 0, 1},
		{"import prepared", casestore.JoinImportPrepared, "", casestore.JoinImported, 0, 1},
		{"import requested", casestore.JoinImportRequested, "", casestore.JoinImported, 0, 1},
		{"discarded", casestore.JoinDiscarded, "", casestore.JoinDiscarded, 0, 0},
		{"join failed", casestore.JoinFailed, "", casestore.JoinFailed, 0, 0},
		{"imported", casestore.JoinImported, "", casestore.JoinImported, 0, 0},
		{"import failed", casestore.JoinImportFailed, "", casestore.JoinImportFailed, 0, 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			stored := storedJoin(t, test.state, authorized)
			checker := &fakeChecker{}
			joins := &fakeJoinExecutor{execution: storedJoin(t, test.joinResult, authorized)}
			imports := &fakeJoinedFileImporter{execution: storedJoin(
				t, casestore.JoinImported, authorized,
			)}
			executor := testExecutorWithStore(
				t,
				&fakeExecutionStore{join: stored, joinFound: true},
				checker,
				&fakeManualImporter{},
				joins,
				imports,
			)

			result, err := executor.Execute(context.Background(), assembly, decision)
			if err != nil {
				t.Fatal(err)
			}
			if !result.Resumed || result.Join == nil || result.Join.State != test.want ||
				checker.calls != 0 || joins.calls != test.wantJoinCalls ||
				imports.calls != test.wantImports {
				t.Fatalf(
					"result = %#v, calls = %d/%d/%d",
					result,
					checker.calls,
					joins.calls,
					imports.calls,
				)
			}
		})
	}
}

func TestExecutorRejectsStoredJoinForDifferentAuthorization(t *testing.T) {
	t.Parallel()

	assembly, decision, authorized := joinRecoveryScenario(t)
	different := authorized
	different.CapabilityID = "capability:different"
	checker := &fakeChecker{}
	joins := &fakeJoinExecutor{}
	imports := &fakeJoinedFileImporter{}
	executor := testExecutorWithStore(
		t,
		&fakeExecutionStore{
			join:      storedJoin(t, casestore.JoinPrepared, different),
			joinFound: true,
		},
		checker,
		&fakeManualImporter{},
		joins,
		imports,
	)

	result, err := executor.Execute(context.Background(), assembly, decision)
	if err == nil || !result.Resumed || checker.calls != 0 ||
		joins.calls != 0 || imports.calls != 0 {
		t.Fatalf(
			"result = %#v, error = %v, calls = %d/%d/%d",
			result,
			err,
			checker.calls,
			joins.calls,
			imports.calls,
		)
	}
}

func TestExecutorStopsWhenExecutionStoreFails(t *testing.T) {
	t.Parallel()

	assembly, decision, _ := joinRecoveryScenario(t)
	failure := errors.New("execution store unavailable")
	checker := &fakeChecker{}
	executor := testExecutorWithStore(
		t,
		&fakeExecutionStore{err: failure},
		checker,
		&fakeManualImporter{},
		&fakeJoinExecutor{},
		&fakeJoinedFileImporter{},
	)

	if _, err := executor.Execute(context.Background(), assembly, decision); !errors.Is(err, failure) {
		t.Fatalf("error = %v", err)
	}
	if checker.calls != 0 {
		t.Fatalf("checker calls = %d", checker.calls)
	}
}

func TestExecutorChecksNewActionWhenNoExecutionExists(t *testing.T) {
	t.Parallel()

	assembly, decision, _ := joinRecoveryScenario(t)
	checker := &fakeChecker{result: executioncheck.Result{
		Rejections: []executioncheck.Rejection{{Reason: executioncheck.JoinExecutionPresent}},
	}}
	executor := testExecutorWithStore(
		t,
		&fakeExecutionStore{},
		checker,
		&fakeManualImporter{},
		&fakeJoinExecutor{},
		&fakeJoinedFileImporter{},
	)

	result, err := executor.Execute(context.Background(), assembly, decision)
	if err != nil {
		t.Fatal(err)
	}
	if result.Resumed || result.Check.Accepted() || checker.calls != 1 {
		t.Fatalf("result = %#v, checker calls = %d", result, checker.calls)
	}
}

func storedJoin(
	t *testing.T,
	state casestore.JoinExecutionState,
	authorized decisionpolicy.AuthorizedJoin,
) casestore.JoinExecution {
	t.Helper()
	executionID, err := casestore.JoinExecutionID(authorized)
	if err != nil {
		t.Fatal(err)
	}
	return casestore.JoinExecution{
		ExecutionID: executionID, Authorization: authorized, State: state,
	}
}

func joinRecoveryScenario(
	t *testing.T,
) (casebuilder.Assembly, contracts.RepairDecisionV2, decisionpolicy.AuthorizedJoin) {
	t.Helper()
	const caseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	files := []controller.InventoryFile{
		joinInventoryFile("file:first", "first.mkv", 100),
		joinInventoryFile("file:second", "second.mkv", 200),
	}
	assembly := casebuilder.Assembly{
		Request: contracts.RepairCaseV2{
			CaseID: caseID,
			Capabilities: []contracts.Capability{{
				Action:           contracts.CapabilityActionJoinParts,
				CapabilityID:     "capability:join",
				CandidateFileIDS: []string{"file:first", "file:second"},
			}},
		},
		LocalSnapshot: casebuilder.LocalSnapshot{
			CaseID: caseID,
			Observation: casebuilder.Observation{
				Inventory: controller.FileInventory{
					Files: files,
					Paths: []controller.FilePathMapping{
						{FileID: "file:first", AbsolutePath: "/downloads/Movie/first.mkv"},
						{FileID: "file:second", AbsolutePath: "/downloads/Movie/second.mkv"},
					},
				},
				Probes: []casebuilder.FileProbe{
					{FileID: "file:first", Outcome: controller.SuccessfulMediaProbe(joinProbe(10_000, 100))},
					{FileID: "file:second", Outcome: controller.SuccessfulMediaProbe(joinProbe(20_000, 200))},
				},
			},
		},
	}
	decision := contracts.RepairDecisionV2{
		Kind: contracts.ActionJoinParts,
		JoinParts: &contracts.JoinDecision{
			Action:         contracts.JoinDecisionAction(contracts.ActionJoinParts),
			CaseID:         caseID,
			CapabilityID:   "capability:join",
			OrderedFileIDS: []string{"file:first", "file:second"},
		},
	}
	validation := decisionpolicy.ValidateJoin(assembly, decision)
	if !validation.Accepted() {
		t.Fatalf("join validation = %#v", validation)
	}
	return assembly, decision, *validation.Authorized
}

func manualRecoveryScenario(
	t *testing.T,
) (casebuilder.Assembly, contracts.RepairDecisionV2, decisionpolicy.AuthorizedManualImport) {
	t.Helper()
	const (
		caseID     = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		fileID     = controller.FileID("file:manual")
		downloadID = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
		path       = "/downloads/Example.Movie/Example.Movie.mkv"
	)
	movieID := int64(42)
	runtimeMinutes := 60
	durationMS := int64(runtimeMinutes * 60 * 1_000)
	size := int64(100)
	fingerprint := controller.FileFingerprint{Device: 1, Inode: 2, SizeBytes: size, MTimeNS: 3}
	fileIDText := string(fileID)
	binding := controller.RadarrManualImportBinding{
		FileID:              fileID,
		ExpectedFingerprint: fingerprint,
		ImportMode:          controller.RadarrImportModeCopy,
		File: controller.RadarrManualImportCommandFile{
			Path:       path,
			FolderName: "Example.Movie",
			Quality: controller.RadarrQualityModel{
				Quality:  controller.RadarrQuality{ID: 7, Name: "Bluray-1080p"},
				Revision: &controller.RadarrQualityRevision{Version: 1},
			},
			Languages:  []controller.RadarrLanguage{{ID: 1, Name: "English"}},
			DownloadID: downloadID,
			MovieID:    movieID,
		},
	}
	assembly := casebuilder.Assembly{
		Request: contracts.RepairCaseV2{
			CaseID: caseID,
			Capabilities: []contracts.Capability{{
				Action: contracts.CapabilityActionManualImportFile, CapabilityID: "capability:manual",
				FileID: &fileIDText,
			}},
		},
		LocalSnapshot: casebuilder.LocalSnapshot{
			CaseID: caseID,
			Observation: casebuilder.Observation{
				Correlation: controller.DownloadCorrelation{Radarr: controller.RadarrQueueRecord{
					MovieID: &movieID, DownloadID: downloadID,
				}},
				Movie: &controller.RadarrMovie{ID: movieID, RuntimeMinutes: &runtimeMinutes},
				Inventory: controller.FileInventory{
					Files: []controller.InventoryFile{{
						ID: fileID, PathComponents: []string{"Example.Movie.mkv"},
						Fingerprint: fingerprint,
						DownloadFile: &controller.DownloadFileReference{
							LengthBytes: size, BytesCompleted: size, Selected: true,
						},
					}},
					Paths: []controller.FilePathMapping{{FileID: fileID, AbsolutePath: path}},
				},
				Probes: []casebuilder.FileProbe{{
					FileID:  fileID,
					Outcome: controller.SuccessfulMediaProbe(mediaProbe(durationMS, size)),
				}},
			},
			ManualImportBindings: map[string]controller.RadarrManualImportBinding{
				"capability:manual": binding,
			},
		},
	}
	decision := contracts.RepairDecisionV2{
		Kind: contracts.ActionManualImportFile,
		ManualImportFile: &contracts.ManualImportFileDecision{
			Action:       contracts.ManualImportFileDecisionAction(contracts.ActionManualImportFile),
			CaseID:       caseID,
			CapabilityID: "capability:manual",
			FileID:       string(fileID),
		},
	}
	validation := decisionpolicy.ValidateManualImport(assembly, decision)
	if !validation.Accepted() {
		t.Fatalf("manual-import validation = %#v", validation)
	}
	return assembly, decision, *validation.Authorized
}

func joinInventoryFile(id controller.FileID, name string, size int64) controller.InventoryFile {
	return controller.InventoryFile{
		ID: id, PathComponents: []string{name},
		Fingerprint: controller.FileFingerprint{SizeBytes: size},
		DownloadFile: &controller.DownloadFileReference{
			LengthBytes: size, BytesCompleted: size, Selected: true,
		},
	}
}

func joinProbe(durationMS, size int64) controller.ProbeEvidence {
	kind := controller.ProbeStreamVideo
	codec := "h264"
	timeBase := controller.Rational{Numerator: 1, Denominator: 1_000}
	frameRate := controller.Rational{Numerator: 24, Denominator: 1}
	width := int64(1_920)
	height := int64(1_080)
	pixelFormat := "yuv420p"
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska"}, DurationMS: &durationMS, SizeBytes: &size,
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &kind, CodecName: &codec, TimeBase: &timeBase,
			DurationMS: &durationMS, Width: &width, Height: &height,
			PixelFormat: &pixelFormat, AverageRate: &frameRate,
		}},
	}
}

func mediaProbe(durationMS, size int64) controller.ProbeEvidence {
	kind := controller.ProbeStreamVideo
	codec := "h264"
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska"}, DurationMS: &durationMS, SizeBytes: &size,
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &kind, CodecName: &codec, DurationMS: &durationMS,
		}},
	}
}
