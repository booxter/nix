//go:build linux

package reaper

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type ProcessTable interface {
	PIDs() ([]int, error)
	Name(pid int) (string, error)
	Signal(pid int, signal os.Signal) error
}

type Sleeper interface {
	Sleep(duration time.Duration)
}

type SystemSleeper struct{}

func (SystemSleeper) Sleep(duration time.Duration) {
	time.Sleep(duration)
}

type ProcFS struct {
	ProcRoot   string
	CgroupRoot string
}

func (procfs ProcFS) PIDs() ([]int, error) {
	cgroup, err := procfs.cgroupPath()
	if err != nil {
		return nil, err
	}
	contents, err := os.ReadFile(filepath.Join(procfs.CgroupRoot, cgroup, "cgroup.procs"))
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read cgroup processes: %w", err)
	}
	var pids []int
	for _, field := range strings.Fields(string(contents)) {
		pid, err := strconv.Atoi(field)
		if err != nil || pid <= 0 {
			return nil, fmt.Errorf("invalid PID %q in cgroup.procs", field)
		}
		pids = append(pids, pid)
	}
	return pids, nil
}

func (procfs ProcFS) cgroupPath() (string, error) {
	contents, err := os.ReadFile(filepath.Join(procfs.ProcRoot, "self", "cgroup"))
	if err != nil {
		return "", fmt.Errorf("read current cgroup: %w", err)
	}
	for _, line := range strings.Split(string(contents), "\n") {
		parts := strings.SplitN(line, ":", 3)
		if len(parts) != 3 || parts[0] != "0" || parts[1] != "" {
			continue
		}
		path := filepath.Clean(strings.TrimPrefix(parts[2], "/"))
		if path == ".." || strings.HasPrefix(path, "../") {
			return "", fmt.Errorf("invalid cgroup path %q", parts[2])
		}
		if path == "." {
			return "", nil
		}
		return path, nil
	}
	return "", fmt.Errorf("unified cgroup entry not found")
}

func (procfs ProcFS) Name(pid int) (string, error) {
	contents, err := os.ReadFile(filepath.Join(procfs.ProcRoot, strconv.Itoa(pid), "comm"))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(contents)), nil
}

func (ProcFS) Signal(pid int, signal os.Signal) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(signal)
}

func Reap(processes ProcessTable, sleeper Sleeper, output io.Writer, ownPID int) error {
	pids, err := processes.PIDs()
	if err != nil {
		return err
	}
	for _, pid := range pids {
		if pid == ownPID {
			continue
		}
		name, err := processes.Name(pid)
		if err != nil || name != "ssh" {
			continue
		}
		_, _ = fmt.Fprintf(output, "reaping leftover restic ssh helper pid %d\n", pid)
		_ = processes.Signal(pid, syscall.SIGTERM)
		sleeper.Sleep(time.Second)
		_ = processes.Signal(pid, syscall.SIGKILL)
	}
	return nil
}
