package main

import (
	"fmt"
	"os"

	"github.com/booxter/nix-config/sketchybar-tools/internal/diskspace"
	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-disk: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := diskspace.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return diskspace.Run(
		config,
		diskspace.NativeFileSystem{},
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
