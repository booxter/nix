package controller

import "strings"

type RadarrImportMode string

const (
	RadarrImportModeCopy      RadarrImportMode       = "copy"
	RadarrHistoryEventGrabbed RadarrHistoryEventType = "grabbed"
)

// RadarrManualImportCommandFile is the exact per-file payload retained by the
// controller. It is never sent to the planner.
type RadarrManualImportCommandFile struct {
	Path         string
	FolderName   string
	Quality      RadarrQualityModel
	Languages    []RadarrLanguage
	ReleaseGroup string
	IndexerFlags int64
	DownloadID   string
	MovieID      int64
}

// RadarrManualImportBinding gives an opaque file choice one fixed meaning for
// later decision validation and execution.
type RadarrManualImportBinding struct {
	FileID              FileID
	ExpectedFingerprint FileFingerprint
	ImportMode          RadarrImportMode
	File                RadarrManualImportCommandFile
}

// Complete reports whether the binding contains everything needed to submit
// the controller-selected file to Radarr without filling fields later.
func (binding RadarrManualImportBinding) Complete() bool {
	return binding.FileID != "" &&
		binding.ExpectedFingerprint.SizeBytes > 0 &&
		binding.ImportMode == RadarrImportModeCopy &&
		usableOutputPath(binding.File.Path) &&
		(binding.File.FolderName == "" || completeText(binding.File.FolderName)) &&
		completeText(binding.File.Quality.Quality.Name) &&
		validLanguages(binding.File.Languages) &&
		(binding.File.ReleaseGroup == "" || completeText(binding.File.ReleaseGroup)) &&
		completeText(binding.File.DownloadID) &&
		binding.File.MovieID > 0
}

// BindRadarrManualImportFile returns a binding only when the controller can
// construct the complete, source-preserving Radarr command in advance. Media
// interpretation remains the planner's job, so probe and runtime evidence are
// intentionally not inputs to this function.
func BindRadarrManualImportFile(
	file InventoryFile,
	absolutePath string,
	manualImport RadarrManualImport,
	history []RadarrHistoryEvent,
) (RadarrManualImportBinding, bool) {
	assessment := classifyMediaFile(file)
	if !assessment.ProbeCandidate() || isRawDiscPath(file.PathComponents) ||
		manualImport.Path != absolutePath ||
		manualImport.SizeBytes != file.Fingerprint.SizeBytes {
		return RadarrManualImportBinding{}, false
	}

	quality := cloneRadarrQuality(manualImport.Quality)
	languages := cloneRadarrLanguages(manualImport.Languages)
	if quality == nil {
		grab := latestMatchingGrab(history, manualImport.MovieID, manualImport.DownloadID)
		if grab != nil {
			quality = cloneRadarrQuality(grab.Quality)
			if len(languages) == 0 {
				languages = cloneRadarrLanguages(grab.Languages)
			}
		}
	}
	if quality == nil || !completeText(quality.Quality.Name) || !validLanguages(languages) {
		return RadarrManualImportBinding{}, false
	}

	binding := RadarrManualImportBinding{
		FileID:              file.ID,
		ExpectedFingerprint: file.Fingerprint,
		ImportMode:          RadarrImportModeCopy,
		File: RadarrManualImportCommandFile{
			Path:         manualImport.Path,
			FolderName:   manualImport.FolderName,
			Quality:      *quality,
			Languages:    languages,
			ReleaseGroup: manualImport.ReleaseGroup,
			IndexerFlags: manualImport.IndexerFlags,
			DownloadID:   manualImport.DownloadID,
			MovieID:      manualImport.MovieID,
		},
	}
	return binding, binding.Complete()
}

func latestMatchingGrab(
	history []RadarrHistoryEvent,
	movieID int64,
	downloadID string,
) *RadarrHistoryEvent {
	var latest *RadarrHistoryEvent
	for index := range history {
		event := &history[index]
		if event.EventType != RadarrHistoryEventGrabbed || event.MovieID != movieID ||
			!strings.EqualFold(event.DownloadID, downloadID) {
			continue
		}
		if latest == nil || event.OccurredAt.After(latest.OccurredAt) ||
			(event.OccurredAt.Equal(latest.OccurredAt) && event.ID > latest.ID) {
			latest = event
		}
	}
	return latest
}

func cloneRadarrQuality(quality *RadarrQualityModel) *RadarrQualityModel {
	if quality == nil {
		return nil
	}
	cloned := *quality
	if quality.Revision != nil {
		revision := *quality.Revision
		cloned.Revision = &revision
	}
	return &cloned
}

func cloneRadarrLanguages(languages []RadarrLanguage) []RadarrLanguage {
	cloned := make([]RadarrLanguage, len(languages))
	copy(cloned, languages)
	return cloned
}

func validLanguages(languages []RadarrLanguage) bool {
	for _, language := range languages {
		if !completeText(language.Name) {
			return false
		}
	}
	return true
}

func completeText(value string) bool {
	return value != "" && strings.TrimSpace(value) == value
}
