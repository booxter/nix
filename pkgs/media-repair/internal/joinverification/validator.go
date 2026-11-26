package joinverification

import (
	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
)

type RejectionReason string

const (
	ArtifactSizeMismatch     RejectionReason = "artifact_size_mismatch"
	DurationUnavailable      RejectionReason = "duration_unavailable"
	DurationOutsideTolerance RejectionReason = "duration_outside_tolerance"
	OutputContainerMismatch  RejectionReason = "output_container_mismatch"
	StreamLayoutMismatch     RejectionReason = "stream_layout_mismatch"
)

type Rejection struct {
	Reason RejectionReason
}

func ValidateOutput(authorized decisionpolicy.AuthorizedJoin, evidence controller.ProbeEvidence, sizeBytes int64) []Rejection {
	var rejections []Rejection
	if evidence.Format.SizeBytes == nil || *evidence.Format.SizeBytes <= 0 ||
		*evidence.Format.SizeBytes != sizeBytes {
		rejections = append(rejections, Rejection{Reason: ArtifactSizeMismatch})
	}

	duration := controller.AssessProbeDuration(evidence)
	if duration.Conflict || duration.EffectiveMS == nil {
		rejections = append(rejections, Rejection{Reason: DurationUnavailable})
	} else if !withinTolerance(*duration.EffectiveMS, authorized.ExpectedDurationMS, authorized.DurationToleranceMS) {
		rejections = append(rejections, Rejection{Reason: DurationOutsideTolerance})
	}
	if !matchesContainer(authorized.OutputContainer, evidence.Format.Names) {
		rejections = append(rejections, Rejection{Reason: OutputContainerMismatch})
	}
	if !authorized.ExpectedStreamLayout.MatchesMuxedOutput(evidence.Streams) {
		rejections = append(rejections, Rejection{Reason: StreamLayoutMismatch})
	}

	return rejections
}

func withinTolerance(actual int64, expected int64, tolerance int64) bool {
	if actual < expected {
		return expected-actual <= tolerance
	}
	return actual-expected <= tolerance
}

func matchesContainer(expected controller.OutputContainer, names []string) bool {
	want := ""
	switch expected {
	case controller.OutputContainerAVI:
		want = "avi"
	case controller.OutputContainerMKV:
		want = "matroska"
	case controller.OutputContainerMP4:
		want = "mp4"
	default:
		return false
	}
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}
