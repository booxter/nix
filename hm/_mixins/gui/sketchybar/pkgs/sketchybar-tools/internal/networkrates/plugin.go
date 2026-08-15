package networkrates

import (
	"fmt"
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

var units = [...]string{"B", "K", "M", "G", "T", "E", "Z"}

func FormatRate(bytes float64) string {
	if bytes < 0 {
		bytes = 0
	}
	unit := 0
	for bytes >= 1024 && unit < len(units)-1 {
		bytes /= 1024
		unit++
	}
	if unit == 0 {
		return fmt.Sprintf("%.0f%s", bytes, units[unit])
	}
	return fmt.Sprintf("%.1f%s", bytes, units[unit])
}

func Run(config Config, provider MetricsProvider, bar sketchybar.Runner, now time.Time) error {
	rates, err := provider.Rates(config, now)
	if err != nil {
		rates = Rates{}
	}
	return bar.Run(
		"-m",
		"--set",
		"network.down",
		"label="+FormatRate(rates.Down),
		"--set",
		"network.up",
		"label="+FormatRate(rates.Up),
	)
}
