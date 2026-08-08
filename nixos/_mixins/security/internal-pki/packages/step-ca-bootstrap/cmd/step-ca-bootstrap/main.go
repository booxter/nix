package main

import (
	"context"
	"crypto/rand"
	"flag"
	"fmt"
	"os"

	"github.com/booxter/nix-config/step-ca-bootstrap/internal/bootstrap"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var configPath string
	var stepExecutable string
	flag.StringVar(&configPath, "config", "", "path to the bootstrap JSON configuration")
	flag.StringVar(&stepExecutable, "step", "", "path to the step executable")
	flag.Parse()

	if configPath == "" || stepExecutable == "" || flag.NArg() != 0 {
		flag.Usage()
		os.Exit(2)
	}

	config, err := bootstrap.LoadConfig(configPath)
	if err != nil {
		return err
	}
	initializer := bootstrap.StepInitializer{
		Executable: stepExecutable,
		Stdout:     os.Stdout,
		Stderr:     os.Stderr,
	}
	return bootstrap.Run(context.Background(), config, initializer, rand.Reader)
}
