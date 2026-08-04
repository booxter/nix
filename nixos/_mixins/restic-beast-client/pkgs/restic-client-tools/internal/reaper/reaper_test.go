//go:build linux

package reaper

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
	"time"
)

type fakeProcesses struct {
	pids    []int
	names   map[int]string
	signals map[int][]os.Signal
}

func (processes *fakeProcesses) PIDs() ([]int, error) {
	return processes.pids, nil
}

func (processes *fakeProcesses) Name(pid int) (string, error) {
	name, exists := processes.names[pid]
	if !exists {
		return "", os.ErrNotExist
	}
	return name, nil
}

func (processes *fakeProcesses) Signal(pid int, signal os.Signal) error {
	processes.signals[pid] = append(processes.signals[pid], signal)
	return nil
}

type recordingSleeper struct {
	durations []time.Duration
}

func (sleeper *recordingSleeper) Sleep(duration time.Duration) {
	sleeper.durations = append(sleeper.durations, duration)
}

func TestReapOnlyTerminatesOtherSSHProcesses(t *testing.T) {
	processes := &fakeProcesses{
		pids:    []int{10, 20, 30, 40},
		names:   map[int]string{10: "ssh", 20: "ssh", 30: "restic"},
		signals: map[int][]os.Signal{},
	}
	sleeper := &recordingSleeper{}
	var output bytes.Buffer

	if err := Reap(processes, sleeper, &output, 10); err != nil {
		t.Fatal(err)
	}

	expected := []os.Signal{syscall.SIGTERM, syscall.SIGKILL}
	if !reflect.DeepEqual(processes.signals[20], expected) {
		t.Fatalf("unexpected SSH signals: %#v", processes.signals[20])
	}
	if len(processes.signals[10]) != 0 || len(processes.signals[30]) != 0 || len(processes.signals[40]) != 0 {
		t.Fatal("non-target process received a signal")
	}
	if !reflect.DeepEqual(sleeper.durations, []time.Duration{time.Second}) {
		t.Fatalf("unexpected grace periods: %#v", sleeper.durations)
	}
	if output.String() != "reaping leftover restic ssh helper pid 20\n" {
		t.Fatalf("unexpected output: %q", output.String())
	}
}

func TestProcFSReadsUnifiedCgroupProcessesAndNames(t *testing.T) {
	root := t.TempDir()
	procRoot := filepath.Join(root, "proc")
	cgroupRoot := filepath.Join(root, "cgroup")
	if err := os.MkdirAll(filepath.Join(procRoot, "self"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(procRoot, "self", "cgroup"),
		[]byte("0::/system.slice/restic.service\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	cgroup := filepath.Join(cgroupRoot, "system.slice", "restic.service")
	if err := os.MkdirAll(cgroup, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cgroup, "cgroup.procs"), []byte("21\n34\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(procRoot, "21"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(procRoot, "21", "comm"), []byte("ssh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	procfs := ProcFS{ProcRoot: procRoot, CgroupRoot: cgroupRoot}

	pids, err := procfs.PIDs()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(pids, []int{21, 34}) {
		t.Fatalf("unexpected PIDs: %#v", pids)
	}
	name, err := procfs.Name(21)
	if err != nil || name != "ssh" {
		t.Fatalf("unexpected process name %q: %v", name, err)
	}
}

func TestProcFSRejectsInvalidOrMissingCgroupState(t *testing.T) {
	root := t.TempDir()
	procRoot := filepath.Join(root, "proc")
	if err := os.MkdirAll(filepath.Join(procRoot, "self"), 0o755); err != nil {
		t.Fatal(err)
	}
	procfs := ProcFS{ProcRoot: procRoot, CgroupRoot: filepath.Join(root, "cgroup")}
	if _, err := procfs.PIDs(); err == nil {
		t.Fatal("missing cgroup metadata was accepted")
	}
	if err := os.WriteFile(
		filepath.Join(procRoot, "self", "cgroup"),
		[]byte("0::/missing.slice\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	pids, err := procfs.PIDs()
	if err != nil || pids != nil {
		t.Fatalf("missing cgroup.procs was not ignored: %#v, %v", pids, err)
	}
	_, err = procfs.Name(99)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatal("missing process name did not report os.ErrNotExist")
	}
}
