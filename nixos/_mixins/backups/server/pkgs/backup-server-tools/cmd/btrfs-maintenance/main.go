//go:build linux

package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"

	"github.com/booxter/nix-config/backup-server-tools/internal/btrfsmaint"
)

func runEnsureSubvolume(ctx context.Context, arguments []string, stderr io.Writer) error {
	flags := flag.NewFlagSet("btrfs-maintenance ensure-subvolume", flag.ContinueOnError)
	flags.SetOutput(stderr)
	btrfsExecutable := flags.String("btrfs", "", "path to the btrfs executable")
	path := flags.String("path", "", "subvolume path")
	modeText := flags.String("mode", "0750", "subvolume mode in octal")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *btrfsExecutable == "" || *path == "" || flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("expected --btrfs, --path, and no positional arguments")
	}
	mode, err := strconv.ParseUint(*modeText, 8, 32)
	if err != nil || mode > 0o7777 {
		return fmt.Errorf("invalid octal mode %q", *modeText)
	}
	client := btrfsmaint.CLI{Executable: *btrfsExecutable, Stdout: os.Stdout, Stderr: os.Stderr}
	return btrfsmaint.EnsureSubvolume(ctx, client, *path, os.FileMode(mode))
}

func runScrubCommand(ctx context.Context, name string, arguments []string, stderr io.Writer) error {
	flags := flag.NewFlagSet("btrfs-maintenance "+name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	btrfsExecutable := flags.String("btrfs", "", "path to the btrfs executable")
	mount := flags.String("mount", "", "Btrfs mount point")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *btrfsExecutable == "" || *mount == "" || flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("expected --btrfs, --mount, and no positional arguments")
	}
	client := btrfsmaint.CLI{Executable: *btrfsExecutable, Stdout: os.Stdout, Stderr: os.Stderr}
	switch name {
	case "scrub-start-or-resume":
		return btrfsmaint.StartOrResumeScrub(ctx, client, *mount)
	case "scrub-resume-if-interrupted":
		return btrfsmaint.ResumeInterruptedScrub(ctx, client, *mount)
	default:
		return fmt.Errorf("unknown scrub command %q", name)
	}
}

func run(ctx context.Context, arguments []string, stderr io.Writer) error {
	if len(arguments) == 0 {
		return fmt.Errorf("expected a maintenance command")
	}
	switch arguments[0] {
	case "ensure-subvolume":
		return runEnsureSubvolume(ctx, arguments[1:], stderr)
	case "scrub-start-or-resume", "scrub-resume-if-interrupted":
		return runScrubCommand(ctx, arguments[0], arguments[1:], stderr)
	default:
		return fmt.Errorf("unknown maintenance command %q", arguments[0])
	}
}

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stderr); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
