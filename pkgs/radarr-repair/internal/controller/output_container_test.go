package controller

import (
	"reflect"
	"testing"
)

func TestSelectOutputContainerPreservesContainerFamily(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		input InputContainer
		want  OutputContainer
	}{
		{name: "MP4", input: InputContainerMP4, want: OutputContainerMP4},
		{name: "Matroska", input: InputContainerMatroska, want: OutputContainerMKV},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got := SelectOutputContainer(confirmedInputContainer(test.input))
			want := OutputContainerAssessment{Container: outputContainerValue(test.want)}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("assessment = %#v, want %#v", got, want)
			}
		})
	}
}

func TestSelectOutputContainerRejectsUndefinedCrossContainerRemuxing(t *testing.T) {
	t.Parallel()

	for _, input := range []InputContainer{InputContainerMPEGTS, InputContainerAVI} {
		input := input
		t.Run(string(input), func(t *testing.T) {
			t.Parallel()
			assertOutputContainerIssue(
				t,
				SelectOutputContainer(confirmedInputContainer(input)),
				OutputContainerCrossContainerPolicyUndefined,
			)
		})
	}
}

func TestSelectOutputContainerRequiresConfirmedInput(t *testing.T) {
	t.Parallel()

	container := InputContainerMP4
	tests := []struct {
		name  string
		input InputContainerAssessment
	}{
		{name: "unknown", input: InputContainerAssessment{Status: InputContainerUnknown}},
		{name: "incompatible", input: InputContainerAssessment{Status: InputContainerIncompatible}},
		{name: "missing container", input: InputContainerAssessment{Status: InputContainerConfirmed}},
		{
			name: "contradictory issue",
			input: InputContainerAssessment{
				Status:    InputContainerConfirmed,
				Container: &container,
				Issue:     &InputContainerIssue{Reason: InputContainerProbeFormatMismatch},
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			assertOutputContainerIssue(
				t,
				SelectOutputContainer(test.input),
				OutputContainerInputUnconfirmed,
			)
		})
	}
}

func TestSelectOutputContainerRejectsUnsupportedInput(t *testing.T) {
	t.Parallel()

	assertOutputContainerIssue(
		t,
		SelectOutputContainer(confirmedInputContainer("other")),
		OutputContainerUnsupportedInput,
	)
}

func confirmedInputContainer(container InputContainer) InputContainerAssessment {
	return InputContainerAssessment{
		Status:    InputContainerConfirmed,
		Container: inputContainerValue(container),
	}
}

func assertOutputContainerIssue(
	t *testing.T,
	assessment OutputContainerAssessment,
	reason OutputContainerIssueReason,
) {
	t.Helper()
	if assessment.Container != nil || assessment.Issue == nil || assessment.Issue.Reason != reason {
		t.Fatalf("assessment = %#v", assessment)
	}
}
