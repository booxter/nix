package clock

import (
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

const labelLayout = "02/01 15:04"

func Run(config Config, now time.Time, bar sketchybar.Runner) error {
	return bar.Run("--set", config.Name, "label="+now.Format(labelLayout))
}
