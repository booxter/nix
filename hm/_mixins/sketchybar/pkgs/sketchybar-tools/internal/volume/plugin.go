package volume

import (
	"strconv"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

const volumeChangeSender = "volume_change"

func Run(config Config, bar sketchybar.Runner) error {
	if config.Sender != volumeChangeSender {
		return nil
	}
	return bar.Run(
		"--set", config.Name,
		"icon="+icon(config.Volume),
		"label="+config.Volume+"%",
	)
}

func icon(rawVolume string) string {
	volume, err := strconv.Atoi(rawVolume)
	if err != nil {
		return "󰖁"
	}
	switch {
	case volume >= 60 && volume <= 100:
		return "󰕾"
	case volume >= 30 && volume < 60:
		return "󰖀"
	case volume >= 1 && volume < 30:
		return "󰕿"
	default:
		return "󰖁"
	}
}
