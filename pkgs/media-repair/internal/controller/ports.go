package controller

import (
	"context"
	"time"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/planning"
)

type Clock interface {
	Now() time.Time
}

type Planner interface {
	Plan(context.Context, contracts.RepairCaseV3, planning.Options) (contracts.RepairDecisionV3, error)
}
