package main

import (
	"fmt"
	"os"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
	"github.com/booxter/nix-config/sketchybar-tools/internal/volume"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-volume: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := volume.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return volume.Run(
		config,
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
