//go:build linux

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"

	"github.com/booxter/nix-config/qosctl/internal/qos"
)

func run(arguments []string, stderr io.Writer) (retErr error) {
	flags := flag.NewFlagSet("qosctl", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", "", "path to the generated JSON configuration")
	limitName := flags.String("limit", "", "named limit to update")
	rateMbit := flags.Float64("rate-mbit", 0, "new limit rate in Mbit/s")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *configPath == "" || flags.NArg() != 1 {
		flags.Usage()
		return fmt.Errorf("expected --config and one action: start, stop, or set-rate")
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
	case "set-rate":
		if *limitName == "" || *rateMbit <= 0 {
			return fmt.Errorf("set-rate requires --limit and a positive --rate-mbit")
		}
		rateBits := uint64(math.Round(*rateMbit * 1_000_000))
		return kernel.SetRate(config, *limitName, rateBits)
	default:
		return fmt.Errorf("unknown action %q: expected start, stop, or set-rate", flags.Arg(0))
	}
}

func main() {
	if err := run(os.Args[1:], os.Stderr); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
