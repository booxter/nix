package machine

import (
	"context"
	"fmt"
)

type Desired struct {
	Name           string
	Provider       string
	CPUs           int
	MemoryMiB      int
	MinimumDiskGiB int
}

func (d Desired) Validate() error {
	if d.Name == "" || d.Provider == "" {
		return fmt.Errorf("--name and --provider are required")
	}
	if d.CPUs <= 0 || d.MemoryMiB <= 0 || d.MinimumDiskGiB <= 0 {
		return fmt.Errorf("--cpus, --memory, and --disk-size must be positive")
	}
	return nil
}

type Summary struct {
	Name     string
	Provider string
}

type State struct {
	CPUs      int
	MemoryMiB int
	DiskGiB   int
	Status    string
}

type Update struct {
	CPUs      *int
	MemoryMiB *int
	DiskGiB   *int
}

func (u Update) Empty() bool {
	return u.CPUs == nil && u.MemoryMiB == nil && u.DiskGiB == nil
}

type Client interface {
	List(context.Context) ([]Summary, error)
	Init(context.Context, Desired) error
	Inspect(context.Context, string) (State, error)
	Stop(context.Context, string) error
	Set(context.Context, string, Update) error
	Start(context.Context, string) error
}

func Ensure(ctx context.Context, client Client, desired Desired) (err error) {
	if err := desired.Validate(); err != nil {
		return err
	}
	machines, err := client.List(ctx)
	if err != nil {
		return err
	}
	matching := make([]Summary, 0, 1)
	for _, candidate := range machines {
		if candidate.Name == desired.Name {
			matching = append(matching, candidate)
		}
	}
	if len(matching) > 1 {
		return fmt.Errorf("multiple Podman machines named %s exist across providers", desired.Name)
	}
	if len(matching) == 1 && matching[0].Provider != desired.Provider {
		return fmt.Errorf(
			"Podman machine %s uses provider %s; expected %s; remove or rename it manually",
			desired.Name,
			matching[0].Provider,
			desired.Provider,
		)
	}
	if len(matching) == 0 {
		if err := client.Init(ctx, desired); err != nil {
			return err
		}
	}

	current, err := client.Inspect(ctx, desired.Name)
	if err != nil {
		return err
	}
	update := requiredUpdate(current, desired)
	restartOnFailure := false
	defer func() {
		if err != nil && restartOnFailure {
			_ = client.Start(ctx, desired.Name)
		}
	}()
	if !update.Empty() {
		if current.Status != "stopped" {
			restartOnFailure = true
			if err = client.Stop(ctx, desired.Name); err != nil {
				return err
			}
		}
		if err = client.Set(ctx, desired.Name, update); err != nil {
			return err
		}
		current, err = client.Inspect(ctx, desired.Name)
		if err != nil {
			return err
		}
		if current.CPUs != desired.CPUs || current.MemoryMiB != desired.MemoryMiB || current.DiskGiB < desired.MinimumDiskGiB {
			return fmt.Errorf("Podman machine %s did not converge to the requested resources", desired.Name)
		}
		current.Status = "stopped"
	}
	restartOnFailure = false
	if current.Status != "running" {
		return client.Start(ctx, desired.Name)
	}
	return nil
}

func requiredUpdate(current State, desired Desired) Update {
	update := Update{}
	if current.CPUs != desired.CPUs {
		update.CPUs = &desired.CPUs
	}
	if current.MemoryMiB != desired.MemoryMiB {
		update.MemoryMiB = &desired.MemoryMiB
	}
	if current.DiskGiB < desired.MinimumDiskGiB {
		update.DiskGiB = &desired.MinimumDiskGiB
	}
	return update
}
