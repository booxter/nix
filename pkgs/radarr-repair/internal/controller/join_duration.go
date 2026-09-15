package controller

import "math"

const joinMuxToleranceMS int64 = 1_000

type JoinDurationIssueReason string

const (
	JoinDurationTooFewParts JoinDurationIssueReason = "too_few_parts"
	JoinDurationMissing     JoinDurationIssueReason = "missing_duration"
	JoinDurationConflict    JoinDurationIssueReason = "duration_conflict"
	JoinDurationOverflow    JoinDurationIssueReason = "duration_overflow"
)

type JoinDurationIssue struct {
	Reason       JoinDurationIssueReason
	PartPosition *int
}

type JoinDurationAssessment struct {
	Parts       []ProbeDurationAssessment
	ExpectedMS  *int64
	ToleranceMS *int64
	Issue       *JoinDurationIssue
}

func AssessJoinDuration(parts []ProbeEvidence) JoinDurationAssessment {
	assessment := JoinDurationAssessment{
		Parts: make([]ProbeDurationAssessment, len(parts)),
	}
	for position, part := range parts {
		assessment.Parts[position] = AssessProbeDuration(part)
	}
	if len(parts) < 2 {
		assessment.Issue = &JoinDurationIssue{Reason: JoinDurationTooFewParts}
		return assessment
	}

	expected := int64(0)
	tolerance := joinMuxToleranceMS
	for position, part := range assessment.Parts {
		if part.Conflict {
			assessment.Issue = joinDurationIssue(JoinDurationConflict, position)
			return assessment
		}
		if part.EffectiveMS == nil {
			assessment.Issue = joinDurationIssue(JoinDurationMissing, position)
			return assessment
		}
		if *part.EffectiveMS > math.MaxInt64-expected {
			assessment.Issue = joinDurationIssue(JoinDurationOverflow, position)
			return assessment
		}
		expected += *part.EffectiveMS

		partTolerance := durationAgreementToleranceMS
		if part.FormatMS != nil && part.LongestStreamMS != nil {
			partTolerance = absoluteDifference(*part.FormatMS, *part.LongestStreamMS)
		}
		if partTolerance > math.MaxInt64-tolerance {
			assessment.Issue = joinDurationIssue(JoinDurationOverflow, position)
			return assessment
		}
		tolerance += partTolerance
	}

	assessment.ExpectedMS = int64Value(expected)
	assessment.ToleranceMS = int64Value(tolerance)
	return assessment
}

func absoluteDifference(left int64, right int64) int64 {
	if left < right {
		return right - left
	}
	return left - right
}

func joinDurationIssue(reason JoinDurationIssueReason, position int) *JoinDurationIssue {
	return &JoinDurationIssue{Reason: reason, PartPosition: &position}
}
