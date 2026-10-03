package repair

import (
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

func Guidance(job jobs.Job) planning.Options {
	return planning.Options{
		PriorDecision:              job.Plan,
		Guidance:                   job.Guidance,
		MaximumRuntimeDifferenceMS: job.RuntimeToleranceMS,
	}
}
