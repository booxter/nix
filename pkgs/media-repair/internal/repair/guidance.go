package repair

import (
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

func Guidance(job jobs.Job, caseID string) (reconsideration.Request, error) {
	var policy *reconsideration.PolicyOverrides
	if job.RuntimeToleranceMS != 0 {
		policy = &reconsideration.PolicyOverrides{MaximumRuntimeDifferenceMS: job.RuntimeToleranceMS}
	}

	return reconsideration.NewRequest(
		reconsideration.Service(job.Service), caseID, job.Guidance, policy, job.UpdatedAt,
	)
}
