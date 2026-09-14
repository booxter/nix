package decisionpolicy

import (
	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

const minimumRuntimeToleranceMS int64 = 5 * 60 * 1_000

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

type ManualImportRejection struct {
	Reason ManualImportRejectionReason
}

type ManualImportRuntimeAssessment struct {
	FileDurationMS int64
	MovieRuntimeMS *int64
	DifferenceMS   *int64
	ToleranceMS    *int64
}

type AuthorizedManualImport struct {
	CaseID              string
	CapabilityID        string
	FileID              controller.FileID
	ExpectedFingerprint controller.FileFingerprint
	ImportMode          controller.RadarrImportMode
	File                controller.RadarrManualImportCommandFile
	ProbeDurationMS     int64
}

type ManualImportValidation struct {
	Authorized *AuthorizedManualImport
	Rejections []ManualImportRejection
	Runtime    *ManualImportRuntimeAssessment
}

func (validation ManualImportValidation) Accepted() bool {
	return validation.Authorized != nil && len(validation.Rejections) == 0
}

func ValidateManualImport(
	assembly casebuilder.Assembly,
	decision contracts.RepairDecisionV2,
) ManualImportValidation {
	validation := ManualImportValidation{Rejections: make([]ManualImportRejection, 0)}
	if decision.Kind != contracts.ActionManualImportFile || decision.ManualImportFile == nil ||
		string(decision.ManualImportFile.Action) != string(contracts.ActionManualImportFile) {
		return rejectManualImport(validation, ManualImportWrongDecisionAction)
	}
	manualImport := decision.ManualImportFile
	if manualImport.CaseID != assembly.Request.CaseID ||
		assembly.LocalSnapshot.CaseID != assembly.Request.CaseID {
		validation = rejectManualImport(validation, ManualImportCaseMismatch)
	}

	capability, found := findCapability(
		assembly.Request.Capabilities,
		manualImport.CapabilityID,
	)
	if !found {
		return rejectManualImport(validation, ManualImportCapabilityNotFound)
	}
	if capability.Action != contracts.CapabilityActionManualImportFile {
		return rejectManualImport(validation, ManualImportCapabilityWrongAction)
	}
	if capability.FileID == nil || *capability.FileID != manualImport.FileID {
		return rejectManualImport(validation, ManualImportFileMismatch)
	}

	binding, found := assembly.LocalSnapshot.ManualImportBindings[manualImport.CapabilityID]
	if !found {
		return rejectManualImport(validation, ManualImportBindingNotFound)
	}
	fileID := controller.FileID(manualImport.FileID)
	if binding.FileID != fileID {
		return rejectManualImport(validation, ManualImportFileMismatch)
	}
	if !binding.Complete() {
		validation = rejectManualImport(validation, ManualImportBindingIncomplete)
	}

	files := indexFiles(assembly.LocalSnapshot.Observation.Inventory)
	file, found := files[fileID]
	if !found {
		return rejectManualImport(validation, ManualImportFileNotInSnapshot)
	}
	assessment := controller.ClassifyMediaFiles(
		controller.FileInventory{Files: []controller.InventoryFile{file}},
	)[0]
	if !assessment.ProbeCandidate() {
		validation = rejectManualImport(validation, ManualImportFileNotActionable)
	}
	if binding.ExpectedFingerprint != file.Fingerprint {
		validation = rejectManualImport(validation, ManualImportFingerprintChanged)
	}
	path, found := findFilePath(assembly.LocalSnapshot.Observation.Inventory, fileID)
	if !found || path != binding.File.Path {
		validation = rejectManualImport(validation, ManualImportPathChanged)
	}

	observation := assembly.LocalSnapshot.Observation
	if binding.File.DownloadID != observation.Correlation.Radarr.DownloadID {
		validation = rejectManualImport(validation, ManualImportDownloadMismatch)
	}
	if observation.Movie == nil || observation.Correlation.Radarr.MovieID == nil ||
		binding.File.MovieID != observation.Movie.ID ||
		binding.File.MovieID != *observation.Correlation.Radarr.MovieID {
		validation = rejectManualImport(validation, ManualImportMovieMismatch)
	}

	probe, found := indexProbes(observation.Probes)[fileID]
	if !found || probe.Status != controller.MediaProbeSucceeded || probe.Evidence == nil {
		return rejectManualImport(validation, ManualImportProbeUnavailable)
	}
	if !hasVideo(probe.Evidence.Streams) {
		validation = rejectManualImport(validation, ManualImportVideoMissing)
	}
	duration := controller.AssessProbeDuration(*probe.Evidence)
	if duration.Conflict || duration.EffectiveMS == nil {
		return rejectManualImport(validation, ManualImportDurationUnavailable)
	}
	validation.Runtime = assessManualImportRuntime(
		*duration.EffectiveMS,
		movieRuntime(observation.Movie),
	)
	if validation.Runtime.DifferenceMS != nil &&
		*validation.Runtime.DifferenceMS > *validation.Runtime.ToleranceMS {
		validation = rejectManualImport(validation, ManualImportRuntimeMismatch)
	}
	if len(validation.Rejections) != 0 {
		return validation
	}

	validation.Authorized = &AuthorizedManualImport{
		CaseID:              assembly.Request.CaseID,
		CapabilityID:        capability.CapabilityID,
		FileID:              binding.FileID,
		ExpectedFingerprint: binding.ExpectedFingerprint,
		ImportMode:          binding.ImportMode,
		File:                cloneManualImportCommand(binding.File),
		ProbeDurationMS:     *duration.EffectiveMS,
	}
	return validation
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

func movieRuntime(movie *controller.RadarrMovie) *int {
	if movie == nil {
		return nil
	}
	return movie.RuntimeMinutes
}

func assessManualImportRuntime(
	fileDurationMS int64,
	movieRuntimeMinutes *int,
) *ManualImportRuntimeAssessment {
	assessment := &ManualImportRuntimeAssessment{FileDurationMS: fileDurationMS}
	if movieRuntimeMinutes == nil {
		return assessment
	}
	movieDurationMS := int64(*movieRuntimeMinutes) * 60 * 1_000
	differenceMS := movieDurationMS - fileDurationMS
	if fileDurationMS > movieDurationMS {
		differenceMS = fileDurationMS - movieDurationMS
	}
	toleranceMS := movieDurationMS / 10
	if toleranceMS < minimumRuntimeToleranceMS {
		toleranceMS = minimumRuntimeToleranceMS
	}
	assessment.MovieRuntimeMS = &movieDurationMS
	assessment.DifferenceMS = &differenceMS
	assessment.ToleranceMS = &toleranceMS
	return assessment
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

func rejectManualImport(
	validation ManualImportValidation,
	reason ManualImportRejectionReason,
) ManualImportValidation {
	validation.Rejections = append(validation.Rejections, ManualImportRejection{Reason: reason})
	return validation
}
