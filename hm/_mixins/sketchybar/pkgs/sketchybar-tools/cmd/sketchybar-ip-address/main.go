package main

import (
	"fmt"
	"os"

	"github.com/booxter/nix-config/sketchybar-tools/internal/networkstatus"
	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sketchybar-ip-address: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	config, err := networkstatus.ConfigFromEnvironment(os.Getenv)
	if err != nil {
		return err
	}
	return networkstatus.Run(
		config,
		networkstatus.NativeInterfaceProvider{},
		sketchybar.Command{Executable: config.SketchybarExecutable},
	)
}
