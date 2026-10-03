package planning

import "encoding/json"

// Options carry operator intent alongside current media evidence. A previous
// decision is optional: guidance also applies to a job's first planning attempt.
type Options struct {
	PriorDecision              json.RawMessage `json:"prior_decision,omitempty"`
	Guidance                   string          `json:"operator_guidance,omitempty"`
	MaximumRuntimeDifferenceMS int64           `json:"maximum_runtime_difference_ms,omitempty"`
}
