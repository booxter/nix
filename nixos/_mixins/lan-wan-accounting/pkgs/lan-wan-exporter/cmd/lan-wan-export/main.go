package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/booxter/nix-config/lan-wan-exporter/internal/accounting"
	"github.com/booxter/nix-config/lan-wan-exporter/internal/kernel"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "lan-wan-export: %v\n", err)
		os.Exit(1)
	}
}

func run(arguments []string) error {
	flags := flag.NewFlagSet("lan-wan-export", flag.ContinueOnError)
	configuration := accounting.Config{}
	flags.StringVar(&configuration.Table, "table", "observability_lan_wan", "nftables table name")
	flags.StringVar(&configuration.Subclass, "wan-subclass", "", "optional WAN subclass counter prefix")
	flags.StringVar(&configuration.Interface, "interface", "", "interface containing the authoritative tc class")
	flags.StringVar(&configuration.TCClass, "wan-tc-class", "", "authoritative WAN transmit tc class")
	output := flags.String("output", "", "node exporter textfile path")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments: %v", flags.Args())
	}
	if *output == "" {
		return fmt.Errorf("--output is required")
	}

	snapshot, err := accounting.Collect(kernel.NFTCounters{}, kernel.TCClasses{}, configuration)
	if err != nil {
		return err
	}
	return accounting.WriteTextfile(*output, snapshot)
}
