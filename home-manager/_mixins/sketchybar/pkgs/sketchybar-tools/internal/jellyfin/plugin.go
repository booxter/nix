package jellyfin

import (
	"context"
	"fmt"
	"strings"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

type MetricsFetcher interface {
	Fetch(ctx context.Context) ([]byte, error)
}

func Run(ctx context.Context, config Config, fetcher MetricsFetcher, bar sketchybar.Runner) error {
	metrics, err := fetcher.Fetch(ctx)
	if err != nil {
		return showError(config, bar)
	}
	sessions, err := ParseMetrics(strings.NewReader(string(metrics)))
	if err != nil {
		return showError(config, bar)
	}
	if len(sessions) == 0 {
		if err := hidePopupRows(config.Name, bar); err != nil {
			return err
		}
		return bar.Run("--set", config.Name, "drawing=off", "popup.drawing=off")
	}

	if err := bar.Run(
		"--set",
		config.Name+".bandwidth",
		"drawing=on",
		"label="+AggregateBandwidth(sessions),
	); err != nil {
		return err
	}
	for index, session := range sessions {
		if index >= maxPopupSessions {
			break
		}
		if err := bar.Run(
			"--set",
			fmt.Sprintf("%s.session.%d", config.Name, index),
			"drawing=on",
			"label="+SessionLabel(session),
		); err != nil {
			return err
		}
	}
	for index := min(len(sessions), maxPopupSessions); index < maxPopupSessions; index++ {
		if err := bar.Run(
			"--set",
			fmt.Sprintf("%s.session.%d", config.Name, index),
			"drawing=off",
		); err != nil {
			return err
		}
	}

	active := 0
	for _, session := range sessions {
		if session.Playing {
			active++
		}
	}
	color := config.Purple
	if active == 0 {
		color = config.Yellow
	}
	arguments := []string{
		"--set",
		config.Name,
		"drawing=on",
		"icon=󰼁",
		"icon.color=" + color,
		fmt.Sprintf("label=%d", len(sessions)),
		"label.color=" + color,
	}
	if config.Sender == "mouse.clicked" {
		arguments = append(arguments, "popup.drawing=toggle")
	}
	return bar.Run(arguments...)
}

func hidePopupRows(name string, bar sketchybar.Runner) error {
	if err := bar.Run("--set", name+".bandwidth", "drawing=off"); err != nil {
		return err
	}
	for index := range maxPopupSessions {
		if err := bar.Run(
			"--set",
			fmt.Sprintf("%s.session.%d", name, index),
			"drawing=off",
		); err != nil {
			return err
		}
	}
	return nil
}

func showError(config Config, bar sketchybar.Runner) error {
	if err := hidePopupRows(config.Name, bar); err != nil {
		return err
	}
	return bar.Run(
		"--set",
		config.Name,
		"drawing=on",
		"popup.drawing=off",
		"icon=!",
		"icon.color="+config.Yellow,
		"label=?",
		"label.color="+config.Yellow,
	)
}
