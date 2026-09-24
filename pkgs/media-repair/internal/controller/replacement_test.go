package controller

import "testing"

func TestClassifyReplacement(t *testing.T) {
	t.Parallel()

	existing := &RadarrMovie{HasFile: true}
	tests := []struct {
		name       string
		movie      *RadarrMovie
		rejections []RadarrManualImportRejectionReason
		want       ReplacementSafety
	}{
		{name: "missing movie", want: ReplacementNotRequired},
		{name: "movie without file", movie: &RadarrMovie{}, want: ReplacementNotRequired},
		{name: "accepted", movie: existing, want: ReplacementAllowed},
		{
			name: "full decision rejection", movie: existing,
			rejections: []RadarrManualImportRejectionReason{RejectionMultiPartMovie},
			want:       ReplacementAllowed,
		},
		{
			name: "quality downgrade", movie: existing,
			rejections: []RadarrManualImportRejectionReason{RejectionNotQualityUpgrade},
			want:       ReplacementSuperseded,
		},
		{
			name: "revision downgrade", movie: existing,
			rejections: []RadarrManualImportRejectionReason{RejectionNotRevisionUpgrade},
			want:       ReplacementSuperseded,
		},
		{
			name: "custom format downgrade", movie: existing,
			rejections: []RadarrManualImportRejectionReason{RejectionNotCustomFormatUpgrade},
			want:       ReplacementSuperseded,
		},
		{
			name: "downgrade remains conclusive with another error", movie: existing,
			rejections: []RadarrManualImportRejectionReason{
				RejectionDecisionError, RejectionNotQualityUpgrade,
			},
			want: ReplacementSuperseded,
		},
		{
			name: "parse failure", movie: existing,
			rejections: []RadarrManualImportRejectionReason{RejectionUnableToParse},
			want:       ReplacementUnproved,
		},
		{
			name: "decision failure", movie: existing,
			rejections: []RadarrManualImportRejectionReason{RejectionDecisionError},
			want:       ReplacementUnproved,
		},
		{
			name: "future rejection", movie: existing,
			rejections: []RadarrManualImportRejectionReason{"futureReason"},
			want:       ReplacementUnproved,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			manualImport := replacementManualImport(test.rejections...)
			if got := ClassifyReplacement(test.movie, manualImport); got != test.want {
				t.Fatalf("replacement safety = %q, want %q", got, test.want)
			}
		})
	}
}

func TestAllReplacementsSuperseded(t *testing.T) {
	t.Parallel()

	existing := &RadarrMovie{HasFile: true}
	if !AllReplacementsSuperseded(existing, []RadarrManualImport{
		replacementManualImport(RejectionNotQualityUpgrade),
		replacementManualImport(RejectionNotCustomFormatUpgrade),
	}) {
		t.Fatal("conclusive downgrade set was not superseded")
	}
	for name, imports := range map[string][]RadarrManualImport{
		"empty": nil,
		"mixed": {
			replacementManualImport(RejectionNotQualityUpgrade),
			replacementManualImport(RejectionMultiPartMovie),
		},
		"unproved": {replacementManualImport(RejectionUnableToParse)},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if AllReplacementsSuperseded(existing, imports) {
				t.Fatal("candidate set was incorrectly superseded")
			}
		})
	}
	if AllReplacementsSuperseded(&RadarrMovie{}, []RadarrManualImport{
		replacementManualImport(RejectionNotQualityUpgrade),
	}) {
		t.Fatal("movie without an existing file was superseded")
	}
}

func replacementManualImport(
	reasons ...RadarrManualImportRejectionReason,
) RadarrManualImport {
	rejections := make([]RadarrManualImportRejection, len(reasons))
	for index, reason := range reasons {
		rejections[index] = RadarrManualImportRejection{Code: reason}
	}
	return RadarrManualImport{Rejections: rejections}
}
