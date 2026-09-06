package controller

import (
	"context"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
)

type Clock interface {
	Now() time.Time
}

type Planner interface {
	Plan(context.Context, contracts.RepairCaseV1) (contracts.RepairDecisionV1, error)
}
