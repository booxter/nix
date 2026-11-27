package repairui

import (
	"fmt"
	"slices"
	"strconv"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

// Choice values come straight from the question. Only the server needs to
// know whether a value identifies a Radarr file or a Lidarr release.
func (input actionRequest) forQuestion(job jobs.Job, question planning.Question) (planning.Answer, error) {
	if question.Kind == planning.Retry {
		if input.Choice != "" || input.Guidance != "" || input.RuntimeMinutes != nil {
			return planning.Answer{}, fmt.Errorf("a retry uses the previous answer")
		}
		return job.Answer, nil
	}

	guidance, tolerance, err := checkGuidance(input.Guidance, input.RuntimeMinutes, job.Service)
	if err != nil {
		return planning.Answer{}, err
	}
	if tolerance != 0 && !question.AllowRuntime {
		return planning.Answer{}, fmt.Errorf("this question does not offer a runtime override")
	}
	if question.Kind == planning.AcceptRuntime && tolerance == 0 {
		return planning.Answer{}, fmt.Errorf("choose the maximum runtime difference you accept")
	}
	if question.RequireGuidance && guidance == "" {
		return planning.Answer{}, fmt.Errorf("provide instructions before requesting another review")
	}

	// A runtime question can follow a file choice. Keep the chosen file.
	answer := job.Answer
	answer.Guidance = guidance
	answer.RuntimeToleranceMS = tolerance
	if len(question.Choices) == 0 && input.Choice == "" {
		return answer, nil
	}
	if !slices.ContainsFunc(question.Choices, func(choice planning.Choice) bool { return choice.Value == input.Choice }) {
		return planning.Answer{}, fmt.Errorf("choose one of the offered options")
	}
	switch question.Kind {
	case planning.ChooseRelease:
		answer.SelectedReleaseID, err = strconv.ParseInt(input.Choice, 10, 64)
	case planning.ChooseFile:
		answer.SelectedFileID = input.Choice
	}
	return answer, err
}
