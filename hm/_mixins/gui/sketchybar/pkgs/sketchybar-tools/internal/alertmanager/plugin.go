package alertmanager

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

const maxPopupAlerts = 8

type AlertFetcher interface {
	Fetch(ctx context.Context) ([]Alert, error)
}

func Run(ctx context.Context, config Config, fetcher AlertFetcher, bar sketchybar.Runner) error {
	alerts, err := fetcher.Fetch(ctx)
	if err != nil {
		return errors.Join(err, showError(config, bar))
	}
	if len(alerts) == 0 {
		if err := hidePopupRows(config.Name, bar); err != nil {
			return err
		}
		return bar.Run("--set", config.Name, "drawing=off", "popup.drawing=off")
	}

	for index, alert := range alerts {
		if index >= maxPopupAlerts {
			break
		}
		if err := bar.Run(
			"--set",
			fmt.Sprintf("%s.alert.%d", config.Name, index),
			"drawing=on",
			"label="+AlertLabel(alert),
			"label.color="+alertColor(config, alert),
		); err != nil {
			return err
		}
	}
	for index := min(len(alerts), maxPopupAlerts); index < maxPopupAlerts; index++ {
		if err := bar.Run(
			"--set",
			fmt.Sprintf("%s.alert.%d", config.Name, index),
			"drawing=off",
		); err != nil {
			return err
		}
	}
	if overflow := len(alerts) - maxPopupAlerts; overflow > 0 {
		if err := bar.Run(
			"--set",
			config.Name+".more",
			"drawing=on",
			fmt.Sprintf("label=… %d more", overflow),
		); err != nil {
			return err
		}
	} else if err := bar.Run("--set", config.Name+".more", "drawing=off"); err != nil {
		return err
	}

	arguments := []string{
		"--set",
		config.Name,
		"drawing=on",
		"icon=!",
		"icon.color=" + config.Red,
		fmt.Sprintf("label=%d", len(alerts)),
		"label.color=" + config.Red,
	}
	if config.Sender == "mouse.clicked" {
		arguments = append(arguments, "popup.drawing=toggle")
	}
	return bar.Run(arguments...)
}

func AlertLabel(alert Alert) string {
	summary := normalizeLabel(alert.Annotations.Summary)
	if summary == "" {
		summary = normalizeLabel(alert.Labels.Name)
	}
	instance := normalizeLabel(alert.Labels.Instance)
	if instance == "" {
		return summary
	}
	if summary == "" {
		return instance
	}
	return instance + " · " + summary
}

func normalizeLabel(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func alertColor(config Config, alert Alert) string {
	if strings.EqualFold(alert.Labels.Severity, "critical") {
		return config.Red
	}
	return config.Yellow
}

func hidePopupRows(name string, bar sketchybar.Runner) error {
	for index := range maxPopupAlerts {
		if err := bar.Run(
			"--set",
			fmt.Sprintf("%s.alert.%d", name, index),
			"drawing=off",
		); err != nil {
			return err
		}
	}
	return bar.Run("--set", name+".more", "drawing=off")
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
