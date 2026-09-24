package controller

type ReplacementSafety string

const (
	ReplacementNotRequired ReplacementSafety = "not_required"
	ReplacementAllowed     ReplacementSafety = "allowed"
	ReplacementSuperseded  ReplacementSafety = "superseded"
	ReplacementUnproved    ReplacementSafety = "unproved"
)

const (
	RejectionInvalidMovie           RadarrManualImportRejectionReason = "invalidMovie"
	RejectionUnableToParse          RadarrManualImportRejectionReason = "unableToParse"
	RejectionError                  RadarrManualImportRejectionReason = "error"
	RejectionDecisionError          RadarrManualImportRejectionReason = "decisionError"
	RejectionMinimumFreeSpace       RadarrManualImportRejectionReason = "minimumFreeSpace"
	RejectionMovieAlreadyImported   RadarrManualImportRejectionReason = "movieAlreadyImported"
	RejectionMovieNotFoundInRelease RadarrManualImportRejectionReason = "movieNotFoundInRelease"
	RejectionMultiPartMovie         RadarrManualImportRejectionReason = "multiPartMovie"
	RejectionNoAudio                RadarrManualImportRejectionReason = "noAudio"
	RejectionNotQualityUpgrade      RadarrManualImportRejectionReason = "notQualityUpgrade"
	RejectionNotRevisionUpgrade     RadarrManualImportRejectionReason = "notRevisionUpgrade"
	RejectionNotCustomFormatUpgrade RadarrManualImportRejectionReason = "notCustomFormatUpgrade"
	RejectionSample                 RadarrManualImportRejectionReason = "sample"
	RejectionSampleIndeterminate    RadarrManualImportRejectionReason = "sampleIndeterminate"
	RejectionUnknownMovie           RadarrManualImportRejectionReason = "unknownMovie"
	RejectionUnpacking              RadarrManualImportRejectionReason = "unpacking"
)

var supersededRejectionReasons = map[RadarrManualImportRejectionReason]struct{}{
	RejectionNotQualityUpgrade:      {},
	RejectionNotRevisionUpgrade:     {},
	RejectionNotCustomFormatUpgrade: {},
}

var incompleteDecisionRejectionReasons = map[RadarrManualImportRejectionReason]struct{}{
	RejectionInvalidMovie:  {},
	RejectionUnableToParse: {},
	RejectionError:         {},
	RejectionDecisionError: {},
}

// These rejections are produced by specifications in Radarr's complete import
// decision pass. Their presence does not make an import valid, but it proves
// that the replacement comparison ran. Unknown future reasons fail closed.
var completedDecisionRejectionReasons = map[RadarrManualImportRejectionReason]struct{}{
	RejectionMinimumFreeSpace:       {},
	RejectionMovieAlreadyImported:   {},
	RejectionMovieNotFoundInRelease: {},
	RejectionMultiPartMovie:         {},
	RejectionNoAudio:                {},
	RejectionSample:                 {},
	RejectionSampleIndeterminate:    {},
	RejectionUnknownMovie:           {},
	RejectionUnpacking:              {},
}

// ClassifyReplacement reports only whether Radarr completed its comparison
// against an existing movie file. Other import rejections remain separate.
func ClassifyReplacement(
	movie *RadarrMovie,
	manualImport RadarrManualImport,
) ReplacementSafety {
	if movie == nil || !movie.HasFile {
		return ReplacementNotRequired
	}
	for _, rejection := range manualImport.Rejections {
		if _, superseded := supersededRejectionReasons[rejection.Code]; superseded {
			return ReplacementSuperseded
		}
	}
	for _, rejection := range manualImport.Rejections {
		if _, incomplete := incompleteDecisionRejectionReasons[rejection.Code]; incomplete {
			return ReplacementUnproved
		}
		if _, completed := completedDecisionRejectionReasons[rejection.Code]; !completed {
			return ReplacementUnproved
		}
	}
	return ReplacementAllowed
}

// AllReplacementsSuperseded requires every manual-import candidate to carry a
// conclusive Radarr downgrade result. Empty and mixed observations stay active.
func AllReplacementsSuperseded(
	movie *RadarrMovie,
	manualImports []RadarrManualImport,
) bool {
	if movie == nil || !movie.HasFile || len(manualImports) == 0 {
		return false
	}
	for _, manualImport := range manualImports {
		if ClassifyReplacement(movie, manualImport) != ReplacementSuperseded {
			return false
		}
	}
	return true
}
