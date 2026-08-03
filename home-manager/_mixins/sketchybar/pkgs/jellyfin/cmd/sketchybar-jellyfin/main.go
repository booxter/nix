package main

import (
	"context"
	"fmt"
	"os"

	jellyfin "github.com/booxter/nix-config/sketchybar-jellyfin"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-jellyfin: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := jellyfin.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return jellyfin.Run(
		context.Background(),
		config,
		jellyfin.NewHTTPMetricsFetcher(config),
		jellyfin.CommandSketchybar{Executable: config.SketchybarExecutable},
	)
}
