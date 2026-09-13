package decisionpolicy

import (
	"reflect"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func TestValidateManualImportReturnsBoundRadarrCommand(t *testing.T) {
	t.Parallel()

	assembly := manualImportAssembly()
	validation := ValidateManualImport(
		assembly,
		manualImportDecision(assembly.Request.CaseID),
	)
	if !validation.Accepted() || validation.Authorized == nil {
		t.Fatalf("validation = %#v", validation)
	}

	binding := assembly.LocalSnapshot.ManualImportBindings["capability:manual"]
	authorized := validation.Authorized
	if authorized.CaseID != assembly.Request.CaseID ||
		authorized.CapabilityID != "capability:manual" ||
		authorized.FileID != binding.FileID ||
		authorized.ExpectedFingerprint != binding.ExpectedFingerprint ||
		authorized.ImportMode != controller.RadarrImportModeCopy ||
		authorized.ProbeDurationMS != 60*60*1_000 ||
		!reflect.DeepEqual(authorized.File, binding.File) {
		t.Fatalf("authorized import = %#v", authorized)
	}
	if validation.Runtime == nil || validation.Runtime.MovieRuntimeMS == nil ||
		*validation.Runtime.MovieRuntimeMS != 60*60*1_000 ||
		*validation.Runtime.DifferenceMS != 0 ||
		*validation.Runtime.ToleranceMS != 6*60*1_000 {
		t.Fatalf("runtime assessment = %#v", validation.Runtime)
	}

	authorized.File.Languages[0].Name = "changed"
	authorized.File.Quality.Revision.Version++
	stored := assembly.LocalSnapshot.ManualImportBindings["capability:manual"]
	if stored.File.Languages[0].Name != "English" ||
		stored.File.Quality.Revision.Version != 1 {
		t.Fatalf("authorized command changed stored binding: %#v", stored)
	}
}

func TestValidateManualImportRequiresGrantedFile(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*casebuilder.Assembly, *contracts.RepairDecisionV1)
		reason ManualImportRejectionReason
	}{
		{
			name: "different case",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV1) {
				decision.ManualImportFile.CaseID = "sha256:different"
			},
			reason: ManualImportCaseMismatch,
		},
		{
			name: "unknown capability",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV1) {
				decision.ManualImportFile.CapabilityID = "capability:unknown"
			},
			reason: ManualImportCapabilityNotFound,
		},
		{
			name: "capability for another action",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV1) {
				assembly.Request.Capabilities[0].Action = contracts.CapabilityActionJoinParts
			},
			reason: ManualImportCapabilityWrongAction,
		},
		{
			name: "different capability file",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV1) {
				fileID := "file:different"
				assembly.Request.Capabilities[0].FileID = &fileID
			},
			reason: ManualImportFileMismatch,
		},
		{
			name: "different decision file",
			mutate: func(_ *casebuilder.Assembly, decision *contracts.RepairDecisionV1) {
				decision.ManualImportFile.FileID = "file:different"
			},
			reason: ManualImportFileMismatch,
		},
		{
			name: "missing binding",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV1) {
				delete(assembly.LocalSnapshot.ManualImportBindings, "capability:manual")
			},
			reason: ManualImportBindingNotFound,
		},
		{
			name: "binding for another file",
			mutate: func(assembly *casebuilder.Assembly, _ *contracts.RepairDecisionV1) {
				binding := assembly.LocalSnapshot.ManualImportBindings["capability:manual"]
				binding.FileID = "file:different"
				assembly.LocalSnapshot.ManualImportBindings["capability:manual"] = binding
			},
			reason: ManualImportFileMismatch,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			assembly := manualImportAssembly()
			decision := manualImportDecision(assembly.Request.CaseID)
			test.mutate(&assembly, &decision)
			assertManualImportRejected(t, ValidateManualImport(assembly, decision), test.reason)
		})
	}
}

func TestValidateManualImportRequiresUnchangedLocalEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*casebuilder.Assembly)
		reason ManualImportRejectionReason
	}{
		{
			name: "incomplete binding",
			mutate: func(assembly *casebuilder.Assembly) {
				binding := assembly.LocalSnapshot.ManualImportBindings["capability:manual"]
				binding.File.Quality.Quality.Name = ""
				assembly.LocalSnapshot.ManualImportBindings["capability:manual"] = binding
			},
			reason: ManualImportBindingIncomplete,
		},
		{
			name: "missing inventory file",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Inventory.Files = nil
			},
			reason: ManualImportFileNotInSnapshot,
		},
		{
			name: "incomplete torrent file",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Inventory.Files[0].TorrentFile.BytesCompleted--
			},
			reason: ManualImportFileNotActionable,
		},
		{
			name: "different fingerprint",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Inventory.Files[0].Fingerprint.MTimeNS++
			},
			reason: ManualImportFingerprintChanged,
		},
		{
			name: "different path",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Inventory.Paths[0].AbsolutePath += ".changed"
			},
			reason: ManualImportPathChanged,
		},
		{
			name: "different download",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Correlation.Radarr.DownloadID = "different"
			},
			reason: ManualImportDownloadMismatch,
		},
		{
			name: "different movie",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Movie.ID++
			},
			reason: ManualImportMovieMismatch,
		},
		{
			name: "missing queue movie",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Correlation.Radarr.MovieID = nil
			},
			reason: ManualImportMovieMismatch,
		},
		{
			name: "failed probe",
			mutate: func(assembly *casebuilder.Assembly) {
				assembly.LocalSnapshot.Observation.Probes[0].Outcome =
					controller.FailedMediaProbe(controller.MediaProbeTimeout)
			},
			reason: ManualImportProbeUnavailable,
		},
		{
			name: "no video",
			mutate: func(assembly *casebuilder.Assembly) {
				evidence := assembly.LocalSnapshot.Observation.Probes[0].Outcome.Evidence
				audio := controller.ProbeStreamAudio
				evidence.Streams[0].Kind = &audio
			},
			reason: ManualImportVideoMissing,
		},
		{
			name: "conflicting duration",
			mutate: func(assembly *casebuilder.Assembly) {
				evidence := assembly.LocalSnapshot.Observation.Probes[0].Outcome.Evidence
				*evidence.Streams[0].DurationMS += 2_000
			},
			reason: ManualImportDurationUnavailable,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			assembly := manualImportAssembly()
			test.mutate(&assembly)
			assertManualImportRejected(
				t,
				ValidateManualImport(assembly, manualImportDecision(assembly.Request.CaseID)),
				test.reason,
			)
		})
	}
}

func TestValidateManualImportRuntimeTolerance(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		runtime    *int
		durationMS int64
		accepted   bool
	}{
		{name: "ten percent boundary", runtime: intValue(60), durationMS: 66 * 60 * 1_000, accepted: true},
		{name: "past ten percent", runtime: intValue(60), durationMS: 66*60*1_000 + 1},
		{name: "five minute floor", runtime: intValue(30), durationMS: 35 * 60 * 1_000, accepted: true},
		{name: "past five minute floor", runtime: intValue(30), durationMS: 35*60*1_000 + 1},
		{name: "missing movie runtime", runtime: nil, durationMS: 60 * 60 * 1_000, accepted: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			assembly := manualImportAssembly()
			assembly.LocalSnapshot.Observation.Movie.RuntimeMinutes = test.runtime
			probe := assembly.LocalSnapshot.Observation.Probes[0].Outcome.Evidence
			probe.Format.DurationMS = &test.durationMS
			probe.Streams[0].DurationMS = &test.durationMS

			validation := ValidateManualImport(
				assembly,
				manualImportDecision(assembly.Request.CaseID),
			)
			if test.accepted && !validation.Accepted() {
				t.Fatalf("validation = %#v", validation)
			}
			if !test.accepted {
				assertManualImportRejected(t, validation, ManualImportRuntimeMismatch)
			}
		})
	}
}

func TestValidateManualImportAllowsSilentVideo(t *testing.T) {
	t.Parallel()

	assembly := manualImportAssembly()
	validation := ValidateManualImport(
		assembly,
		manualImportDecision(assembly.Request.CaseID),
	)
	if !validation.Accepted() {
		t.Fatalf("silent video was rejected: %#v", validation)
	}
}

func TestValidateManualImportRejectsAnotherDecisionVariant(t *testing.T) {
	t.Parallel()

	validation := ValidateManualImport(manualImportAssembly(), contracts.RepairDecisionV1{
		Kind: contracts.ActionNoRepair,
		NoRepair: &contracts.NoRepairDecision{
			Action: contracts.NoRepair,
		},
	})
	assertManualImportRejected(t, validation, ManualImportWrongDecisionAction)
}

func assertManualImportRejected(
	t *testing.T,
	validation ManualImportValidation,
	reason ManualImportRejectionReason,
) {
	t.Helper()
	if validation.Accepted() || validation.Authorized != nil {
		t.Fatalf("decision was authorized: %#v", validation)
	}
	for _, rejection := range validation.Rejections {
		if rejection.Reason == reason {
			return
		}
	}
	t.Fatalf("rejections = %#v, want %q", validation.Rejections, reason)
}

func manualImportAssembly() casebuilder.Assembly {
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
	fingerprint := controller.FileFingerprint{
		Device: 1, Inode: 2, SizeBytes: size, MTimeNS: 3,
	}
	fileIDText := string(fileID)
	revision := &controller.RadarrQualityRevision{Version: 1}
	binding := controller.RadarrManualImportBinding{
		FileID:              fileID,
		ExpectedFingerprint: fingerprint,
		ImportMode:          controller.RadarrImportModeCopy,
		File: controller.RadarrManualImportCommandFile{
			Path:       path,
			FolderName: "Example.Movie",
			Quality: controller.RadarrQualityModel{
				Quality:  controller.RadarrQuality{ID: 7, Name: "Bluray-1080p"},
				Revision: revision,
			},
			Languages:    []controller.RadarrLanguage{{ID: 1, Name: "English"}},
			ReleaseGroup: "GROUP",
			DownloadID:   downloadID,
			MovieID:      movieID,
		},
	}
	return casebuilder.Assembly{
		Request: contracts.RepairCaseV1{
			CaseID: caseID,
			Capabilities: []contracts.Capability{{
				Action:       contracts.CapabilityActionManualImportFile,
				CapabilityID: "capability:manual",
				FileID:       &fileIDText,
			}},
		},
		LocalSnapshot: casebuilder.LocalSnapshot{
			CaseID: caseID,
			Observation: casebuilder.Observation{
				Correlation: controller.DownloadCorrelation{
					Radarr: controller.RadarrQueueRecord{
						MovieID: &movieID, DownloadID: downloadID,
					},
				},
				Movie: &controller.RadarrMovie{
					ID: movieID, RuntimeMinutes: &runtimeMinutes,
				},
				Inventory: controller.FileInventory{
					Files: []controller.InventoryFile{{
						ID: fileID, PathComponents: []string{"Example.Movie.mkv"},
						Fingerprint: fingerprint,
						TorrentFile: &controller.TorrentFileReference{
							LengthBytes: size, BytesCompleted: size, Wanted: true,
						},
					}},
					Paths: []controller.FilePathMapping{{FileID: fileID, AbsolutePath: path}},
				},
				Probes: []casebuilder.FileProbe{{
					FileID: fileID,
					Outcome: controller.SuccessfulMediaProbe(
						manualImportProbe(durationMS, size),
					),
				}},
			},
			ManualImportBindings: map[string]controller.RadarrManualImportBinding{
				"capability:manual": binding,
			},
		},
	}
}

func manualImportDecision(caseID string) contracts.RepairDecisionV1 {
	return contracts.RepairDecisionV1{
		Kind: contracts.ActionManualImportFile,
		ManualImportFile: &contracts.ManualImportFileDecision{
			Action:       contracts.ManualImportFileDecisionAction(contracts.ActionManualImportFile),
			CaseID:       caseID,
			CapabilityID: "capability:manual",
			FileID:       "file:manual",
		},
	}
}

func manualImportProbe(durationMS, size int64) controller.ProbeEvidence {
	video := controller.ProbeStreamVideo
	codec := "h264"
	streamDurationMS := durationMS
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska"}, DurationMS: &durationMS, SizeBytes: &size,
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &video, CodecName: &codec, DurationMS: &streamDurationMS,
		}},
	}
}

func intValue(value int) *int {
	return &value
}
