package main

import (
	"fmt"
	"os"
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/clock"
	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-clock: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := clock.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return clock.Run(
		config,
		time.Now(),
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
