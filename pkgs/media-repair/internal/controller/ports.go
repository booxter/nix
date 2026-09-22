package controller

import (
	"context"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
)

type Clock interface {
	Now() time.Time
}

type Planner interface {
	Plan(context.Context, contracts.RepairCaseV3) (contracts.RepairDecisionV3, error)
}
