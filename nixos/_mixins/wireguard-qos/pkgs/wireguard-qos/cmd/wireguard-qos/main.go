//go:build linux

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/booxter/nix-config/wireguard-qos/internal/qos"
)

func run(arguments []string, stderr io.Writer) (retErr error) {
	flags := flag.NewFlagSet("wireguard-qos", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", "", "path to the generated JSON configuration")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *configPath == "" || flags.NArg() != 1 {
		flags.Usage()
		return fmt.Errorf("expected --config and one action: start or stop")
	}
	config, err := qos.LoadConfig(*configPath)
	if err != nil {
		return err
	}
	kernel, err := qos.OpenKernel()
	if err != nil {
		return err
	}
	defer func() {
		retErr = errors.Join(retErr, kernel.Close())
	}()
	switch flags.Arg(0) {
	case "start":
		return kernel.Start(config)
	case "stop":
		return kernel.Stop(config)
	default:
		return fmt.Errorf("unknown action %q: expected start or stop", flags.Arg(0))
	}
}

func main() {
	if err := run(os.Args[1:], os.Stderr); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
