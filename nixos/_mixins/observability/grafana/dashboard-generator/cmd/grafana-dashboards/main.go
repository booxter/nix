package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/booxter/nix-config/grafana-dashboards/internal/dashboards"
)

func run(args []string) error {
	flags := flag.NewFlagSet("grafana-dashboards", flag.ContinueOnError)
	output := flags.String("output", "", "directory to receive generated dashboards")
	configPath := flags.String("config", "", "JSON file describing dashboard inputs")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *output == "" {
		return fmt.Errorf("--output is required")
	}
	if *configPath == "" {
		return fmt.Errorf("--config is required")
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments: %v", flags.Args())
	}

	configFile, err := os.Open(*configPath)
	if err != nil {
		return fmt.Errorf("open dashboard config: %w", err)
	}
	defer configFile.Close()

	config, err := dashboards.DecodeConfig(configFile)
	if err != nil {
		return err
	}
	return dashboards.WriteAll(dashboards.OSFileWriter{}, config, *output)
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
