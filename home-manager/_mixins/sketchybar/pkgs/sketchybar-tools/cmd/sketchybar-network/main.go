package main

import (
	"fmt"
	"os"
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/networkrates"
	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-network: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := networkrates.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return networkrates.Run(
		config,
		networkrates.NativeMetricsProvider{},
		sketchybar.Command{Executable: config.SketchybarExecutable},
		time.Now(),
	)
}
