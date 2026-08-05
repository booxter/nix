//go:build linux

package main

import (
	"fmt"
	"os"

	"github.com/booxter/nix-config/restic-client-tools/internal/reaper"
)

func main() {
	processes := reaper.ProcFS{ProcRoot: "/proc", CgroupRoot: "/sys/fs/cgroup"}
	if err := reaper.Reap(processes, reaper.SystemSleeper{}, os.Stdout, os.Getpid()); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
