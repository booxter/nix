package planning

import "encoding/json"

// Options carry operator intent alongside current media evidence. A previous
// decision is optional: guidance also applies to a job's first planning attempt.
type Options struct {
	JobID         int64           `json:"job_id,omitempty"`
	PriorDecision json.RawMessage `json:"prior_decision,omitempty"`
	Answer
}

// An operator can pick an offered file or release and optionally add instructions.
// Keep the IDs separate from the text so the planner can use the choice directly.
type Answer struct {
	Guidance           string `json:"operator_guidance,omitempty"`
	RuntimeToleranceMS int64  `json:"maximum_runtime_difference_ms,omitempty"`
	SelectedFileID     string `json:"selected_file_id,omitempty"`
	SelectedReleaseID  int64  `json:"selected_release_id,omitempty"`
}
