package decisionpolicy

import (
	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const minimumRuntimeToleranceMS int64 = 5 * 60 * 1_000

type RuntimePolicy struct {
	MaximumDifferenceMS int64
}

type ManualImportRejectionReason string

const (
	ManualImportWrongDecisionAction   ManualImportRejectionReason = "wrong_decision_action"
	ManualImportCaseMismatch          ManualImportRejectionReason = "case_mismatch"
	ManualImportCapabilityNotFound    ManualImportRejectionReason = "capability_not_found"
	ManualImportCapabilityWrongAction ManualImportRejectionReason = "capability_wrong_action"
	ManualImportFileMismatch          ManualImportRejectionReason = "file_mismatch"
	ManualImportBindingNotFound       ManualImportRejectionReason = "binding_not_found"
	ManualImportBindingIncomplete     ManualImportRejectionReason = "binding_incomplete"
	ManualImportFileNotInSnapshot     ManualImportRejectionReason = "file_not_in_snapshot"
	ManualImportFileNotActionable     ManualImportRejectionReason = "file_not_actionable"
	ManualImportFingerprintChanged    ManualImportRejectionReason = "fingerprint_changed"
	ManualImportPathChanged           ManualImportRejectionReason = "path_changed"
	ManualImportDownloadMismatch      ManualImportRejectionReason = "download_mismatch"
	ManualImportMovieMismatch         ManualImportRejectionReason = "movie_mismatch"
	ManualImportProbeUnavailable      ManualImportRejectionReason = "probe_unavailable"
	ManualImportVideoMissing          ManualImportRejectionReason = "video_missing"
	ManualImportDurationUnavailable   ManualImportRejectionReason = "duration_unavailable"
	ManualImportRuntimeMismatch       ManualImportRejectionReason = "runtime_mismatch"
)

type AuthorizedManualImport struct {
	ImportMode controller.RadarrImportMode
	File       controller.RadarrManualImportCommandFile
}

func ValidateManualImport(
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV3,
	policy RuntimePolicy,
) (*AuthorizedManualImport, ManualImportRejectionReason) {
	if decision.Kind != contracts.ActionManualImportFile || decision.ManualImportFile == nil ||
		string(decision.ManualImportFile.Action) != string(contracts.ActionManualImportFile) {
		return nil, ManualImportWrongDecisionAction
	}
	manualImport := decision.ManualImportFile
	if manualImport.CaseID != assembly.Request.CaseID ||
		assembly.LocalSnapshot.CaseID != assembly.Request.CaseID {
		return nil, ManualImportCaseMismatch
	}

	capability, found := findCapability(
		assembly.Request.Capabilities,
		manualImport.CapabilityID,
	)
	if !found {
		return nil, ManualImportCapabilityNotFound
	}
	if capability.Action != contracts.CapabilityActionManualImportFile {
		return nil, ManualImportCapabilityWrongAction
	}
	if capability.FileID == nil || *capability.FileID != manualImport.FileID {
		return nil, ManualImportFileMismatch
	}

	binding, found := assembly.LocalSnapshot.ManualImportBindings[manualImport.CapabilityID]
	if !found {
		return nil, ManualImportBindingNotFound
	}
	fileID := controller.FileID(manualImport.FileID)
	if binding.FileID != fileID {
		return nil, ManualImportFileMismatch
	}
	if !binding.Complete() {
		return nil, ManualImportBindingIncomplete
	}

	files := indexFiles(assembly.LocalSnapshot.Observation.Inventory)
	file, found := files[fileID]
	if !found {
		return nil, ManualImportFileNotInSnapshot
	}
	assessment := controller.ClassifyMediaFiles(
		controller.FileInventory{Files: []controller.InventoryFile{file}},
	)[0]
	if !assessment.ProbeCandidate() {
		return nil, ManualImportFileNotActionable
	}
	if binding.ExpectedFingerprint != file.Fingerprint {
		return nil, ManualImportFingerprintChanged
	}
	path, found := findFilePath(assembly.LocalSnapshot.Observation.Inventory, fileID)
	if !found || path != binding.File.Path {
		return nil, ManualImportPathChanged
	}

	observation := assembly.LocalSnapshot.Observation
	if binding.File.DownloadID != observation.Correlation.Radarr.DownloadID {
		return nil, ManualImportDownloadMismatch
	}
	if observation.Movie == nil || observation.Correlation.Radarr.MovieID == nil ||
		binding.File.MovieID != observation.Movie.ID ||
		binding.File.MovieID != *observation.Correlation.Radarr.MovieID {
		return nil, ManualImportMovieMismatch
	}

	probe, found := indexProbes(observation.Probes)[fileID]
	if !found || probe.Status != controller.MediaProbeSucceeded || probe.Evidence == nil {
		return nil, ManualImportProbeUnavailable
	}
	if !hasVideo(probe.Evidence.Streams) {
		return nil, ManualImportVideoMissing
	}
	duration := controller.AssessProbeDuration(*probe.Evidence)
	if duration.Conflict || duration.EffectiveMS == nil {
		return nil, ManualImportDurationUnavailable
	}
	if _, matches := runtimeMatches(*duration.EffectiveMS, observation.Movie.RuntimeMinutes, policy); !matches {
		return nil, ManualImportRuntimeMismatch
	}

	return &AuthorizedManualImport{
		ImportMode: binding.ImportMode,
		File:       cloneManualImportCommand(binding.File),
	}, ""
}

func findFilePath(
	inventory controller.FileInventory,
	fileID controller.FileID,
) (string, bool) {
	for _, mapping := range inventory.Paths {
		if mapping.FileID == fileID {
			return mapping.AbsolutePath, true
		}
	}
	return "", false
}

func hasVideo(streams []controller.ProbeStream) bool {
	for _, stream := range streams {
		if stream.Kind != nil && *stream.Kind == controller.ProbeStreamVideo {
			return true
		}
	}
	return false
}

func runtimeMatches(
	fileDurationMS int64,
	movieRuntimeMinutes *int,
	policy RuntimePolicy,
) (int64, bool) {
	if movieRuntimeMinutes == nil {
		return 0, true
	}
	movieDurationMS := int64(*movieRuntimeMinutes) * 60 * 1_000
	differenceMS := movieDurationMS - fileDurationMS
	if fileDurationMS > movieDurationMS {
		differenceMS = fileDurationMS - movieDurationMS
	}
	defaultToleranceMS := movieDurationMS / 10
	if defaultToleranceMS < minimumRuntimeToleranceMS {
		defaultToleranceMS = minimumRuntimeToleranceMS
	}
	toleranceMS := defaultToleranceMS
	if policy.MaximumDifferenceMS > toleranceMS {
		toleranceMS = policy.MaximumDifferenceMS
	}
	return toleranceMS, differenceMS <= toleranceMS
}

func cloneManualImportCommand(
	command controller.RadarrManualImportCommandFile,
) controller.RadarrManualImportCommandFile {
	cloned := command
	cloned.Languages = append([]controller.RadarrLanguage(nil), command.Languages...)
	if command.Quality.Revision != nil {
		revision := *command.Quality.Revision
		cloned.Quality.Revision = &revision
	}
	return cloned
}
