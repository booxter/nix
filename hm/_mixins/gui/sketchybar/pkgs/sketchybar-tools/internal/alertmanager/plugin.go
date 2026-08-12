package alertmanager

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

type AlertCounter interface {
	Count(ctx context.Context) (int, error)
}

func Run(ctx context.Context, config Config, counter AlertCounter, bar sketchybar.Runner) error {
	count, err := counter.Count(ctx)
	if err != nil {
		return showError(config, bar)
	}
	if count == 0 {
		return bar.Run("--set", config.Name, "drawing=off")
	}
	return bar.Run(
		"--set",
		config.Name,
		"drawing=on",
		"icon=!",
		"icon.color="+config.Red,
		fmt.Sprintf("label=%d", count),
		"label.color="+config.Red,
	)
}

func showError(config Config, bar sketchybar.Runner) error {
	return bar.Run(
		"--set",
		config.Name,
		"drawing=on",
		"icon=!",
		"icon.color="+config.Yellow,
		"label=?",
		"label.color="+config.Yellow,
	)
}
