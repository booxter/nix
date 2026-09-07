package controller

type InputContainer string

const (
	InputContainerMPEGTS   InputContainer = "mpegts"
	InputContainerMP4      InputContainer = "mp4"
	InputContainerMatroska InputContainer = "matroska"
	InputContainerAVI      InputContainer = "avi"
)

type InputContainerStatus string

const (
	InputContainerConfirmed    InputContainerStatus = "confirmed"
	InputContainerIncompatible InputContainerStatus = "incompatible"
	InputContainerUnknown      InputContainerStatus = "unknown"
)

type InputContainerIssueReason string

const (
	InputContainerTooFewParts          InputContainerIssueReason = "too_few_parts"
	InputContainerUnsupportedExtension InputContainerIssueReason = "unsupported_extension"
	InputContainerMixedExtensions      InputContainerIssueReason = "mixed_extensions"
	InputContainerMissingProbeFormat   InputContainerIssueReason = "missing_probe_format"
	InputContainerProbeFormatMismatch  InputContainerIssueReason = "probe_format_mismatch"
)

type InputContainerObservation struct {
	Extension   MediaExtension
	FormatNames []string
}

type InputContainerIssue struct {
	Reason       InputContainerIssueReason
	PartPosition *int
}

type InputContainerAssessment struct {
	Status    InputContainerStatus
	Container *InputContainer
	Issue     *InputContainerIssue
}

func AssessInputContainer(observations []InputContainerObservation) InputContainerAssessment {
	if len(observations) < 2 {
		return inputContainerFailure(InputContainerUnknown, InputContainerTooFewParts, nil)
	}

	want, supported := containerForExtension(observations[0].Extension)
	if !supported {
		position := 0
		return inputContainerFailure(
			InputContainerIncompatible,
			InputContainerUnsupportedExtension,
			&position,
		)
	}

	var missingFormatPosition *int
	for position, observation := range observations {
		container, supported := containerForExtension(observation.Extension)
		if !supported {
			return inputContainerFailure(
				InputContainerIncompatible,
				InputContainerUnsupportedExtension,
				&position,
			)
		}
		if container != want {
			return inputContainerFailure(
				InputContainerIncompatible,
				InputContainerMixedExtensions,
				&position,
			)
		}
		if len(observation.FormatNames) == 0 {
			if missingFormatPosition == nil {
				firstMissing := position
				missingFormatPosition = &firstMissing
			}
			continue
		}
		if !containsFormatName(observation.FormatNames, string(want)) {
			return inputContainerFailure(
				InputContainerIncompatible,
				InputContainerProbeFormatMismatch,
				&position,
			)
		}
	}

	if missingFormatPosition != nil {
		return inputContainerFailure(
			InputContainerUnknown,
			InputContainerMissingProbeFormat,
			missingFormatPosition,
		)
	}
	return InputContainerAssessment{
		Status:    InputContainerConfirmed,
		Container: inputContainerValue(want),
	}
}

func containerForExtension(extension MediaExtension) (InputContainer, bool) {
	switch extension {
	case MediaExtensionTS:
		return InputContainerMPEGTS, true
	case MediaExtensionMP4:
		return InputContainerMP4, true
	case MediaExtensionMKV:
		return InputContainerMatroska, true
	case MediaExtensionAVI:
		return InputContainerAVI, true
	default:
		return "", false
	}
}

func containsFormatName(names []string, want string) bool {
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}

func inputContainerFailure(
	status InputContainerStatus,
	reason InputContainerIssueReason,
	position *int,
) InputContainerAssessment {
	return InputContainerAssessment{
		Status: status,
		Issue: &InputContainerIssue{
			Reason:       reason,
			PartPosition: position,
		},
	}
}

func inputContainerValue(value InputContainer) *InputContainer {
	return &value
}
