package controller

import (
	"reflect"
	"testing"
)

func TestAssessInputContainerConfirmsExtensionAndProbeFormat(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		extension   MediaExtension
		formatNames []string
		want        InputContainer
	}{
		{
			name:        "transport stream",
			extension:   MediaExtensionTS,
			formatNames: []string{"mpegts"},
			want:        InputContainerMPEGTS,
		},
		{
			name:        "MP4 among related formats",
			extension:   MediaExtensionMP4,
			formatNames: []string{"mov", "mp4", "m4a", "3gp", "3g2", "mj2"},
			want:        InputContainerMP4,
		},
		{
			name:        "Matroska among related formats",
			extension:   MediaExtensionMKV,
			formatNames: []string{"matroska", "webm"},
			want:        InputContainerMatroska,
		},
		{
			name:        "AVI",
			extension:   MediaExtensionAVI,
			formatNames: []string{"avi"},
			want:        InputContainerAVI,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			observations := []InputContainerObservation{
				{Extension: test.extension, FormatNames: test.formatNames},
				{Extension: test.extension, FormatNames: test.formatNames},
			}
			got := AssessInputContainer(observations)
			want := InputContainerAssessment{
				Status:    InputContainerConfirmed,
				Container: inputContainerValue(test.want),
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("assessment = %#v, want %#v", got, want)
			}
		})
	}
}

func TestAssessInputContainerRejectsKnownContradictions(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name         string
		observations []InputContainerObservation
		reason       InputContainerIssueReason
		position     int
	}{
		{
			name: "unsupported extension",
			observations: []InputContainerObservation{
				{Extension: "mov", FormatNames: []string{"mov"}},
				{Extension: "mov", FormatNames: []string{"mov"}},
			},
			reason:   InputContainerUnsupportedExtension,
			position: 0,
		},
		{
			name: "mixed extensions",
			observations: []InputContainerObservation{
				{Extension: MediaExtensionMKV, FormatNames: []string{"matroska", "webm"}},
				{Extension: MediaExtensionMP4, FormatNames: []string{"mov", "mp4"}},
			},
			reason:   InputContainerMixedExtensions,
			position: 1,
		},
		{
			name: "probe format mismatch",
			observations: []InputContainerObservation{
				{Extension: MediaExtensionMKV, FormatNames: []string{"matroska", "webm"}},
				{Extension: MediaExtensionMKV, FormatNames: []string{"avi"}},
			},
			reason:   InputContainerProbeFormatMismatch,
			position: 1,
		},
		{
			name: "known mismatch dominates missing format",
			observations: []InputContainerObservation{
				{Extension: MediaExtensionMKV},
				{Extension: MediaExtensionMKV, FormatNames: []string{"avi"}},
			},
			reason:   InputContainerProbeFormatMismatch,
			position: 1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got := AssessInputContainer(test.observations)
			assertInputContainerIssue(
				t,
				got,
				InputContainerIncompatible,
				test.reason,
				test.position,
			)
		})
	}
}

func TestAssessInputContainerReturnsUnknownForMissingEvidence(t *testing.T) {
	t.Parallel()

	got := AssessInputContainer([]InputContainerObservation{
		{Extension: MediaExtensionAVI, FormatNames: []string{"avi"}},
		{Extension: MediaExtensionAVI},
	})
	assertInputContainerIssue(
		t,
		got,
		InputContainerUnknown,
		InputContainerMissingProbeFormat,
		1,
	)
}

func TestAssessInputContainerRequiresMultipleParts(t *testing.T) {
	t.Parallel()

	got := AssessInputContainer([]InputContainerObservation{
		{Extension: MediaExtensionMKV, FormatNames: []string{"matroska"}},
	})
	if got.Status != InputContainerUnknown || got.Container != nil || got.Issue == nil ||
		got.Issue.Reason != InputContainerTooFewParts || got.Issue.PartPosition != nil {
		t.Fatalf("assessment = %#v", got)
	}
}

func assertInputContainerIssue(
	t *testing.T,
	assessment InputContainerAssessment,
	status InputContainerStatus,
	reason InputContainerIssueReason,
	position int,
) {
	t.Helper()
	if assessment.Status != status || assessment.Container != nil || assessment.Issue == nil ||
		assessment.Issue.Reason != reason || assessment.Issue.PartPosition == nil ||
		*assessment.Issue.PartPosition != position {
		t.Fatalf("assessment = %#v", assessment)
	}
}
