package main

import (
	"context"
	"fmt"
	"os"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
	"github.com/booxter/nix-config/sketchybar-tools/internal/statuspage"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-statuspage: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := statuspage.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return statuspage.Run(
		context.Background(),
		config,
		statuspage.NewHTTPSummaryFetcher(config),
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
