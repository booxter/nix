package main

import (
	"context"
	"fmt"
	"os"

	"github.com/booxter/nix-config/sketchybar-tools/internal/githubstatus"
	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-github-status: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := githubstatus.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return githubstatus.Run(
		context.Background(),
		config,
		githubstatus.NewHTTPSummaryFetcher(config),
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
