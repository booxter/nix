package controller

import (
	"math"
	"reflect"
	"testing"
)

func TestAssessJoinDurationSumsExactPartDurations(t *testing.T) {
	t.Parallel()

	got := AssessJoinDuration([]ProbeEvidence{
		probeDurations(3_600_000, 3_600_000),
		probeDurations(3_600_000, 3_600_000),
	})
	want := JoinDurationAssessment{
		Parts: []ProbeDurationAssessment{
			{
				FormatMS:        durationPointer(3_600_000),
				LongestStreamMS: durationPointer(3_600_000),
				EffectiveMS:     durationPointer(3_600_000),
				Source:          DurationSourceConsistentFormatAndStream,
			},
			{
				FormatMS:        durationPointer(3_600_000),
				LongestStreamMS: durationPointer(3_600_000),
				EffectiveMS:     durationPointer(3_600_000),
				Source:          DurationSourceConsistentFormatAndStream,
			},
		},
		ExpectedMS:  durationPointer(7_200_000),
		ToleranceMS: durationPointer(1_000),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("assessment = %#v, want %#v", got, want)
	}
}

func TestAssessJoinDurationIncludesObservedDisagreementInTolerance(t *testing.T) {
	t.Parallel()

	got := AssessJoinDuration([]ProbeEvidence{
		probeDurations(10_000, 10_300),
		probeDurations(20_500, 20_000),
	})
	assertJoinDuration(t, got, 30_800, 1_800)
}

func TestAssessJoinDurationAllowsForSingleSourceParts(t *testing.T) {
	t.Parallel()

	got := AssessJoinDuration([]ProbeEvidence{
		{Format: ProbeFormat{DurationMS: durationPointer(10_000)}},
		{Streams: []ProbeStream{probeStream(ProbeStreamVideo, 20_000)}},
	})
	assertJoinDuration(t, got, 30_000, 3_000)
}

func TestAssessJoinDurationRejectsUnusableParts(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		parts    []ProbeEvidence
		reason   JoinDurationIssueReason
		position *int
	}{
		{
			name: "too few parts",
			parts: []ProbeEvidence{
				probeDurations(10_000, 10_000),
			},
			reason: JoinDurationTooFewParts,
		},
		{
			name: "missing duration",
			parts: []ProbeEvidence{
				probeDurations(10_000, 10_000),
				{},
			},
			reason:   JoinDurationMissing,
			position: durationPosition(1),
		},
		{
			name: "conflicting duration",
			parts: []ProbeEvidence{
				probeDurations(10_000, 10_000),
				probeDurations(20_000, 21_001),
			},
			reason:   JoinDurationConflict,
			position: durationPosition(1),
		},
		{
			name: "sum overflow",
			parts: []ProbeEvidence{
				{Format: ProbeFormat{DurationMS: durationPointer(math.MaxInt64)}},
				{Format: ProbeFormat{DurationMS: durationPointer(1)}},
			},
			reason:   JoinDurationOverflow,
			position: durationPosition(1),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got := AssessJoinDuration(test.parts)
			if got.ExpectedMS != nil || got.ToleranceMS != nil || got.Issue == nil ||
				got.Issue.Reason != test.reason ||
				!reflect.DeepEqual(got.Issue.PartPosition, test.position) {
				t.Fatalf("assessment = %#v", got)
			}
		})
	}
}

func probeDurations(formatMS int64, streamMS int64) ProbeEvidence {
	return ProbeEvidence{
		Format: ProbeFormat{DurationMS: durationPointer(formatMS)},
		Streams: []ProbeStream{
			probeStream(ProbeStreamVideo, streamMS),
		},
	}
}

func assertJoinDuration(
	t *testing.T,
	assessment JoinDurationAssessment,
	expectedMS int64,
	toleranceMS int64,
) {
	t.Helper()
	if assessment.Issue != nil || assessment.ExpectedMS == nil ||
		*assessment.ExpectedMS != expectedMS || assessment.ToleranceMS == nil ||
		*assessment.ToleranceMS != toleranceMS {
		t.Fatalf("assessment = %#v", assessment)
	}
}

func durationPosition(value int) *int {
	return &value
}
