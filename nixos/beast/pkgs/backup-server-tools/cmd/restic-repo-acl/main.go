//go:build linux

package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/booxter/nix-config/backup-server-tools/internal/repoacl"
)

func run(arguments []string, stderr io.Writer) error {
	flags := flag.NewFlagSet("restic-repo-acl", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", "", "path to the generated JSON configuration")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *configPath == "" || flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("expected --config and no positional arguments")
	}

	config, err := repoacl.LoadConfig(*configPath)
	if err != nil {
		return err
	}
	return repoacl.Sync(config, repoacl.Setfacl{Executable: config.SetfaclExecutable})
}

func main() {
	if err := run(os.Args[1:], os.Stderr); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
