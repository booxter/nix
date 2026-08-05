package main

import (
	"context"
	"fmt"
	"os"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
	"github.com/booxter/nix-config/sketchybar-tools/internal/stock"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-stock: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := stock.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	fetcher, err := stock.NewHTTPQuoteFetcher(config)
	if err != nil {
		return err
	}
	return stock.Run(
		context.Background(),
		config,
		fetcher,
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
