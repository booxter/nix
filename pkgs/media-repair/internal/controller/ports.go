package controller

import (
	"context"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
)

type Clock interface {
	Now() time.Time
}

type Planner interface {
	Plan(context.Context, contracts.RepairCaseV3) (contracts.RepairDecisionV3, error)
	Reconsider(
		context.Context,
		contracts.RepairCaseV3,
		contracts.RepairDecisionV3,
		reconsideration.Request,
	) (contracts.RepairDecisionV3, error)
}
