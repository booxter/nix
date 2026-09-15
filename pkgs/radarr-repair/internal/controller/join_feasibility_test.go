package controller

import (
	"math"
	"reflect"
	"testing"
)

func TestAssessJoinFeasibilityCombinesJoinFacts(t *testing.T) {
	t.Parallel()

	firstProbe := joinableProbe(InputContainerMatroska, 10_000)
	secondProbe := joinableProbe(InputContainerMatroska, 20_000)
	got := AssessJoinFeasibility([]JoinPartEvidence{
		joinPart("file:first", MediaExtensionMKV, 100, &firstProbe),
		joinPart("file:second", MediaExtensionMKV, 200, &secondProbe),
	})

	if !got.Eligible() {
		t.Fatalf("assessment is not eligible: %#v", got)
	}
	if !reflect.DeepEqual(got.FileIDs, []FileID{"file:first", "file:second"}) {
		t.Fatalf("file IDs = %#v", got.FileIDs)
	}
	if got.ProbeCoverage != ProbeCoverageComplete || got.SourceBytes == nil || *got.SourceBytes != 300 {
		t.Fatalf("coverage = %q, source bytes = %v", got.ProbeCoverage, got.SourceBytes)
	}
	if got.Duration.ExpectedMS == nil || *got.Duration.ExpectedMS != 30_000 ||
		got.Duration.ToleranceMS == nil || *got.Duration.ToleranceMS != 1_000 {
		t.Fatalf("duration = %#v", got.Duration)
	}
	if got.Streams.Compatibility != StreamsCompatible || got.Streams.Issue != nil {
		t.Fatalf("streams = %#v", got.Streams)
	}
	if got.InputContainer.Container == nil || *got.InputContainer.Container != InputContainerMatroska {
		t.Fatalf("input container = %#v", got.InputContainer)
	}
	if got.OutputContainer.Container == nil || *got.OutputContainer.Container != OutputContainerMKV {
		t.Fatalf("output container = %#v", got.OutputContainer)
	}
}

func TestAssessJoinFeasibilityReportsProbeCoverage(t *testing.T) {
	t.Parallel()

	probe := joinableProbe(InputContainerMP4, 10_000)
	tests := []struct {
		name   string
		probes []*ProbeEvidence
		want   ProbeCoverage
	}{
		{name: "none", probes: []*ProbeEvidence{nil, nil}, want: ProbeCoverageNone},
		{name: "partial", probes: []*ProbeEvidence{&probe, nil}, want: ProbeCoveragePartial},
		{name: "complete", probes: []*ProbeEvidence{&probe, &probe}, want: ProbeCoverageComplete},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got := AssessJoinFeasibility([]JoinPartEvidence{
				joinPart("file:first", MediaExtensionMP4, 100, test.probes[0]),
				joinPart("file:second", MediaExtensionMP4, 200, test.probes[1]),
			})
			if got.ProbeCoverage != test.want {
				t.Fatalf("coverage = %q, want %q", got.ProbeCoverage, test.want)
			}
			if got.Eligible() != (test.want == ProbeCoverageComplete) {
				t.Fatalf("eligible = %t", got.Eligible())
			}
		})
	}
}

func TestAssessJoinFeasibilityRejectsInvalidStructure(t *testing.T) {
	t.Parallel()

	probe := joinableProbe(InputContainerMP4, 10_000)
	tests := []struct {
		name     string
		parts    []JoinPartEvidence
		reason   JoinStructureIssueReason
		position *int
	}{
		{
			name:     "too few parts",
			parts:    []JoinPartEvidence{joinPart("file:first", MediaExtensionMP4, 100, &probe)},
			reason:   JoinStructureTooFewParts,
			position: nil,
		},
		{
			name: "missing file ID",
			parts: []JoinPartEvidence{
				joinPart("file:first", MediaExtensionMP4, 100, &probe),
				joinPart("", MediaExtensionMP4, 100, &probe),
			},
			reason:   JoinStructureMissingFileID,
			position: pointerTo(1),
		},
		{
			name: "duplicate file ID",
			parts: []JoinPartEvidence{
				joinPart("file:first", MediaExtensionMP4, 100, &probe),
				joinPart("file:first", MediaExtensionMP4, 100, &probe),
			},
			reason:   JoinStructureDuplicateFileID,
			position: pointerTo(1),
		},
		{
			name: "invalid source size",
			parts: []JoinPartEvidence{
				joinPart("file:first", MediaExtensionMP4, 100, &probe),
				joinPart("file:second", MediaExtensionMP4, 0, &probe),
			},
			reason:   JoinStructureInvalidSourceSize,
			position: pointerTo(1),
		},
		{
			name: "source size overflow",
			parts: []JoinPartEvidence{
				joinPart("file:first", MediaExtensionMP4, math.MaxInt64, &probe),
				joinPart("file:second", MediaExtensionMP4, 1, &probe),
			},
			reason:   JoinStructureSourceSizeOverflow,
			position: pointerTo(1),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got := AssessJoinFeasibility(test.parts)
			if got.Eligible() || got.SourceBytes != nil || got.StructuralIssue == nil ||
				got.StructuralIssue.Reason != test.reason ||
				!reflect.DeepEqual(got.StructuralIssue.PartPosition, test.position) {
				t.Fatalf("assessment = %#v", got)
			}
		})
	}
}

func TestAssessJoinFeasibilityRequiresSupportedComponentAssessments(t *testing.T) {
	t.Parallel()

	firstProbe := joinableProbe(InputContainerMPEGTS, 10_000)
	secondProbe := joinableProbe(InputContainerMPEGTS, 20_000)
	got := AssessJoinFeasibility([]JoinPartEvidence{
		joinPart("file:first", MediaExtensionTS, 100, &firstProbe),
		joinPart("file:second", MediaExtensionTS, 200, &secondProbe),
	})

	if got.Eligible() || got.StructuralIssue != nil || got.OutputContainer.Issue == nil ||
		got.OutputContainer.Issue.Reason != OutputContainerCrossContainerPolicyUndefined {
		t.Fatalf("assessment = %#v", got)
	}
}

func joinPart(
	fileID FileID,
	extension MediaExtension,
	sizeBytes int64,
	probe *ProbeEvidence,
) JoinPartEvidence {
	return JoinPartEvidence{
		FileID:      fileID,
		Extension:   extension,
		Fingerprint: FileFingerprint{SizeBytes: sizeBytes},
		Probe:       probe,
	}
}

func joinableProbe(container InputContainer, durationMS int64) ProbeEvidence {
	stream := videoStream(0)
	stream.DurationMS = pointerTo(durationMS)
	return ProbeEvidence{
		Format: ProbeFormat{
			Names:      []string{string(container)},
			DurationMS: pointerTo(durationMS),
		},
		Streams: []ProbeStream{stream},
	}
}
