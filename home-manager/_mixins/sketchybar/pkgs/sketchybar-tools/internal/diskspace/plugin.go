package diskspace

import (
	"fmt"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

func Run(config Config, filesystem FileSystem, bar sketchybar.Runner) error {
	usage, err := filesystem.Usage(config.Home)
	if err != nil || usage.TotalBlocks == 0 {
		return nil
	}
	remainingPercentage := usage.AvailableBlocks * 100 / usage.TotalBlocks
	return bar.Run(
		"--set",
		config.Name,
		fmt.Sprintf("label=%d%%", remainingPercentage),
	)
}
