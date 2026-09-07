package controller

import "math"

type ProbeCoverage string

const (
	ProbeCoverageNone     ProbeCoverage = "none"
	ProbeCoveragePartial  ProbeCoverage = "partial"
	ProbeCoverageComplete ProbeCoverage = "complete"
)

type JoinStructureIssueReason string

const (
	JoinStructureTooFewParts        JoinStructureIssueReason = "too_few_parts"
	JoinStructureMissingFileID      JoinStructureIssueReason = "missing_file_id"
	JoinStructureDuplicateFileID    JoinStructureIssueReason = "duplicate_file_id"
	JoinStructureInvalidSourceSize  JoinStructureIssueReason = "invalid_source_size"
	JoinStructureSourceSizeOverflow JoinStructureIssueReason = "source_size_overflow"
)

type JoinPartEvidence struct {
	FileID      FileID
	Extension   MediaExtension
	Fingerprint FileFingerprint
	Probe       *ProbeEvidence
}

type JoinStructureIssue struct {
	Reason       JoinStructureIssueReason
	PartPosition *int
}

type JoinFeasibilityAssessment struct {
	FileIDs         []FileID
	ProbeCoverage   ProbeCoverage
	SourceBytes     *int64
	Duration        JoinDurationAssessment
	Streams         StreamCompatibilityAssessment
	InputContainer  InputContainerAssessment
	OutputContainer OutputContainerAssessment
	StructuralIssue *JoinStructureIssue
}

func AssessJoinFeasibility(parts []JoinPartEvidence) JoinFeasibilityAssessment {
	fileIDs := make([]FileID, len(parts))
	probes := make([]ProbeEvidence, len(parts))
	containerObservations := make([]InputContainerObservation, len(parts))
	probed := 0
	for position, part := range parts {
		fileIDs[position] = part.FileID
		containerObservations[position].Extension = part.Extension
		if part.Probe != nil {
			probes[position] = *part.Probe
			containerObservations[position].FormatNames = part.Probe.Format.Names
			probed++
		}
	}

	inputContainer := AssessInputContainer(containerObservations)
	sourceBytes, structuralIssue := assessJoinStructure(parts)
	return JoinFeasibilityAssessment{
		FileIDs:         fileIDs,
		ProbeCoverage:   probeCoverage(len(parts), probed),
		SourceBytes:     sourceBytes,
		Duration:        AssessJoinDuration(probes),
		Streams:         AssessStreamCompatibility(probes),
		InputContainer:  inputContainer,
		OutputContainer: SelectOutputContainer(inputContainer),
		StructuralIssue: structuralIssue,
	}
}

func (assessment JoinFeasibilityAssessment) Eligible() bool {
	return assessment.StructuralIssue == nil && assessment.ProbeCoverage == ProbeCoverageComplete &&
		assessment.SourceBytes != nil && assessment.Duration.Issue == nil &&
		assessment.Duration.ExpectedMS != nil && assessment.Duration.ToleranceMS != nil &&
		assessment.Streams.Compatibility == StreamsCompatible && assessment.Streams.Issue == nil &&
		assessment.InputContainer.Status == InputContainerConfirmed &&
		assessment.InputContainer.Container != nil && assessment.InputContainer.Issue == nil &&
		assessment.OutputContainer.Container != nil && assessment.OutputContainer.Issue == nil
}

func probeCoverage(parts int, probed int) ProbeCoverage {
	switch {
	case probed == 0:
		return ProbeCoverageNone
	case probed == parts:
		return ProbeCoverageComplete
	default:
		return ProbeCoveragePartial
	}
}

func assessJoinStructure(parts []JoinPartEvidence) (*int64, *JoinStructureIssue) {
	if len(parts) < 2 {
		return nil, &JoinStructureIssue{Reason: JoinStructureTooFewParts}
	}

	seen := make(map[FileID]struct{}, len(parts))
	total := int64(0)
	for position, part := range parts {
		if part.FileID == "" {
			return nil, joinStructureIssue(JoinStructureMissingFileID, position)
		}
		if _, duplicate := seen[part.FileID]; duplicate {
			return nil, joinStructureIssue(JoinStructureDuplicateFileID, position)
		}
		seen[part.FileID] = struct{}{}

		size := part.Fingerprint.SizeBytes
		if size <= 0 {
			return nil, joinStructureIssue(JoinStructureInvalidSourceSize, position)
		}
		if size > math.MaxInt64-total {
			return nil, joinStructureIssue(JoinStructureSourceSizeOverflow, position)
		}
		total += size
	}
	return int64Value(total), nil
}

func joinStructureIssue(reason JoinStructureIssueReason, position int) *JoinStructureIssue {
	return &JoinStructureIssue{Reason: reason, PartPosition: &position}
}
