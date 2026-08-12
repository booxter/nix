package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/booxter/nix-config/podman-machine-ensure/internal/machine"
	"github.com/booxter/nix-config/podman-machine-ensure/internal/podman"
)

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "podman-machine-ensure: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, arguments []string) error {
	flags := flag.NewFlagSet("podman-machine-ensure", flag.ContinueOnError)
	desired := machine.Desired{}
	flags.StringVar(&desired.Name, "name", "", "managed machine name")
	flags.StringVar(&desired.Provider, "provider", "", "required virtualization provider")
	flags.IntVar(&desired.CPUs, "cpus", 0, "desired virtual CPU count")
	flags.IntVar(&desired.MemoryMiB, "memory", 0, "desired memory in MiB")
	flags.IntVar(&desired.MinimumDiskGiB, "disk-size", 0, "minimum disk size in GiB")
	containersConfig := flags.String("containers-config", "", "containers.conf override")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments: %v", flags.Args())
	}
	if err := desired.Validate(); err != nil {
		return err
	}
	if *containersConfig == "" {
		return fmt.Errorf("--containers-config is required")
	}
	client := podman.New("podman", *containersConfig)
	return machine.Ensure(ctx, client, desired)
}
