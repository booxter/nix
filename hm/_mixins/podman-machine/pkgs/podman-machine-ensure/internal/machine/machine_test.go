package machine

import (
	"context"
	"strings"
	"testing"
)

type memoryClient struct {
	summaries    []Summary
	state        State
	initialized  bool
	rejectUpdate bool
}

func (m *memoryClient) List(context.Context) ([]Summary, error) {
	return m.summaries, nil
}

func (m *memoryClient) Init(_ context.Context, desired Desired) error {
	m.initialized = true
	m.summaries = append(m.summaries, Summary{Name: desired.Name, Provider: desired.Provider})
	m.state = State{CPUs: desired.CPUs, MemoryMiB: desired.MemoryMiB, DiskGiB: desired.MinimumDiskGiB, Status: "stopped"}
	return nil
}

func (m *memoryClient) Inspect(context.Context, string) (State, error) {
	return m.state, nil
}

func (m *memoryClient) Stop(context.Context, string) error {
	m.state.Status = "stopped"
	return nil
}

func (m *memoryClient) Set(_ context.Context, _ string, update Update) error {
	if m.rejectUpdate {
		return nil
	}
	if update.CPUs != nil {
		m.state.CPUs = *update.CPUs
	}
	if update.MemoryMiB != nil {
		m.state.MemoryMiB = *update.MemoryMiB
	}
	if update.DiskGiB != nil {
		m.state.DiskGiB = *update.DiskGiB
	}
	return nil
}

func (m *memoryClient) Start(context.Context, string) error {
	m.state.Status = "running"
	return nil
}

func desired() Desired {
	return Desired{Name: "podman-machine-default", Provider: "libkrun", CPUs: 4, MemoryMiB: 8192, MinimumDiskGiB: 100}
}

func TestEnsureCreatesAndStartsMissingMachine(t *testing.T) {
	client := &memoryClient{}
	if err := Ensure(context.Background(), client, desired()); err != nil {
		t.Fatal(err)
	}
	if !client.initialized || client.state.Status != "running" {
		t.Fatalf("machine did not reach running state: %#v", client)
	}
}

func TestEnsureReconcilesResourcesWithoutShrinkingDisk(t *testing.T) {
	client := &memoryClient{
		summaries: []Summary{{Name: desired().Name, Provider: desired().Provider}},
		state:     State{CPUs: 2, MemoryMiB: 4096, DiskGiB: 150, Status: "running"},
	}
	if err := Ensure(context.Background(), client, desired()); err != nil {
		t.Fatal(err)
	}
	if client.state != (State{CPUs: 4, MemoryMiB: 8192, DiskGiB: 150, Status: "running"}) {
		t.Fatalf("unexpected reconciled state: %#v", client.state)
	}
}

func TestEnsureRefusesAmbiguousOrWrongProvider(t *testing.T) {
	for name, summaries := range map[string][]Summary{
		"duplicate": {{Name: desired().Name, Provider: "libkrun"}, {Name: desired().Name, Provider: "applehv"}},
		"provider":  {{Name: desired().Name, Provider: "applehv"}},
	} {
		t.Run(name, func(t *testing.T) {
			client := &memoryClient{summaries: summaries}
			if err := Ensure(context.Background(), client, desired()); err == nil {
				t.Fatal("unsafe machine selection unexpectedly succeeded")
			}
		})
	}
}

func TestFailedConvergenceRestartsPreviouslyRunningMachine(t *testing.T) {
	client := &memoryClient{
		summaries:    []Summary{{Name: desired().Name, Provider: desired().Provider}},
		state:        State{CPUs: 2, MemoryMiB: 8192, DiskGiB: 100, Status: "running"},
		rejectUpdate: true,
	}
	err := Ensure(context.Background(), client, desired())
	if err == nil || !strings.Contains(err.Error(), "did not converge") {
		t.Fatalf("expected convergence error, got %v", err)
	}
	if client.state.Status != "running" {
		t.Fatalf("machine was left stopped after failed update: %#v", client.state)
	}
}
