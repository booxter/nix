package githubstatus

import (
	"context"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

type SummaryFetcher interface {
	Fetch(ctx context.Context) (Summary, error)
}

func Run(ctx context.Context, config Config, fetcher SummaryFetcher, bar sketchybar.Runner) error {
	summary, err := fetcher.Fetch(ctx)
	if err != nil {
		return nil
	}
	if !summary.HasIssues() {
		return bar.Run("--set", config.Name, "drawing=off")
	}
	return bar.Run(
		"--set",
		config.Name,
		"drawing=on",
		"icon=",
		"icon.color="+config.Red,
		"label.drawing=off",
	)
}
