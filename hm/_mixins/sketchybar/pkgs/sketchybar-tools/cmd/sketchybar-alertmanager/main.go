package main

import (
	"context"
	"fmt"
	"os"

	"github.com/booxter/nix-config/sketchybar-tools/internal/alertmanager"
	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-alertmanager: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := alertmanager.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return alertmanager.Run(
		context.Background(),
		config,
		alertmanager.NewHTTPAlertCounter(config),
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
