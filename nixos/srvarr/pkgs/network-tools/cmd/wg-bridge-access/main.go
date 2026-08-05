//go:build linux

package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/booxter/nix-config/srvarr-network-tools/internal/bridgeaccess"
)

func run(arguments []string, stderr io.Writer) error {
	if len(arguments) == 0 {
		return fmt.Errorf("expected apply or remove")
	}
	action := arguments[0]
	if action != "apply" && action != "remove" {
		return fmt.Errorf("unknown action %q", action)
	}
	flags := flag.NewFlagSet("wg-bridge-access "+action, flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", "", "path to the generated JSON configuration")
	if err := flags.Parse(arguments[1:]); err != nil {
		return err
	}
	if *configPath == "" || flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("expected --config and no positional arguments")
	}

	config, err := bridgeaccess.LoadConfig(*configPath)
	if err != nil {
		return err
	}
	store, err := bridgeaccess.OpenNFTStore(config.Namespace)
	if err != nil {
		return err
	}
	defer store.Close()

	switch action {
	case "apply":
		return bridgeaccess.Apply(config, store)
	default:
		return bridgeaccess.Remove(store)
	}
}

func main() {
	if err := run(os.Args[1:], os.Stderr); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
