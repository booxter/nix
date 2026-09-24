package controller

type OutputContainer string

const (
	OutputContainerMP4 OutputContainer = "mp4"
	OutputContainerMKV OutputContainer = "mkv"
	OutputContainerAVI OutputContainer = "avi"
)

type OutputContainerIssueReason string

const (
	OutputContainerInputUnconfirmed              OutputContainerIssueReason = "input_container_unconfirmed"
	OutputContainerCrossContainerPolicyUndefined OutputContainerIssueReason = "cross_container_policy_undefined"
	OutputContainerUnsupportedInput              OutputContainerIssueReason = "unsupported_input_container"
)

type OutputContainerIssue struct {
	Reason OutputContainerIssueReason
}

type OutputContainerAssessment struct {
	Container *OutputContainer
	Issue     *OutputContainerIssue
}

func SelectOutputContainer(input InputContainerAssessment) OutputContainerAssessment {
	if input.Status != InputContainerConfirmed || input.Container == nil || input.Issue != nil {
		return outputContainerFailure(OutputContainerInputUnconfirmed)
	}

	switch *input.Container {
	case InputContainerMP4:
		return OutputContainerAssessment{Container: outputContainerValue(OutputContainerMP4)}
	case InputContainerMatroska:
		return OutputContainerAssessment{Container: outputContainerValue(OutputContainerMKV)}
	case InputContainerAVI:
		return OutputContainerAssessment{Container: outputContainerValue(OutputContainerAVI)}
	case InputContainerMPEGTS:
		// Cross-container remuxing needs explicit codec and metadata compatibility rules.
		return outputContainerFailure(OutputContainerCrossContainerPolicyUndefined)
	default:
		return outputContainerFailure(OutputContainerUnsupportedInput)
	}
}

func outputContainerFailure(reason OutputContainerIssueReason) OutputContainerAssessment {
	return OutputContainerAssessment{Issue: &OutputContainerIssue{Reason: reason}}
}

func outputContainerValue(value OutputContainer) *OutputContainer {
	return &value
}
