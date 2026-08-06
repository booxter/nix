package podman

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"

	"github.com/booxter/nix-config/podman-machine-ensure/internal/machine"
)

type Client struct {
	executable  string
	environment []string
}

func New(executable, containersConfig string) *Client {
	return &Client{
		executable:  executable,
		environment: append(os.Environ(), "CONTAINERS_CONF_OVERRIDE="+containersConfig),
	}
}

func (c *Client) command(ctx context.Context, arguments ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, c.executable, arguments...)
	command.Env = c.environment
	output, err := command.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("podman %v failed: %s: %w", arguments, output, err)
	}
	return output, nil
}

func (c *Client) List(ctx context.Context) ([]machine.Summary, error) {
	output, err := c.command(ctx, "machine", "list", "--all-providers", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList(output)
}

func (c *Client) Init(ctx context.Context, desired machine.Desired) error {
	_, err := c.command(
		ctx,
		"machine",
		"init",
		"--cpus="+strconv.Itoa(desired.CPUs),
		"--disk-size="+strconv.Itoa(desired.MinimumDiskGiB),
		"--memory="+strconv.Itoa(desired.MemoryMiB),
		desired.Name,
	)
	return err
}

func (c *Client) Inspect(ctx context.Context, name string) (machine.State, error) {
	output, err := c.command(ctx, "machine", "inspect", name)
	if err != nil {
		return machine.State{}, err
	}
	return decodeInspect(output)
}

func (c *Client) Stop(ctx context.Context, name string) error {
	_, err := c.command(ctx, "machine", "stop", name)
	return err
}

func (c *Client) Set(ctx context.Context, name string, update machine.Update) error {
	arguments := []string{"machine", "set"}
	if update.CPUs != nil {
		arguments = append(arguments, "--cpus="+strconv.Itoa(*update.CPUs))
	}
	if update.MemoryMiB != nil {
		arguments = append(arguments, "--memory="+strconv.Itoa(*update.MemoryMiB))
	}
	if update.DiskGiB != nil {
		arguments = append(arguments, "--disk-size="+strconv.Itoa(*update.DiskGiB))
	}
	_, err := c.command(ctx, append(arguments, name)...)
	return err
}

func (c *Client) Start(ctx context.Context, name string) error {
	_, err := c.command(ctx, "machine", "start", "--quiet", name)
	return err
}

type listItem struct {
	Name     string `json:"Name"`
	Provider string `json:"VMType"`
}

func decodeList(data []byte) ([]machine.Summary, error) {
	var items []listItem
	if err := json.Unmarshal(data, &items); err != nil {
		return nil, fmt.Errorf("decode podman machine list: %w", err)
	}
	result := make([]machine.Summary, 0, len(items))
	for _, item := range items {
		result = append(result, machine.Summary{Name: item.Name, Provider: item.Provider})
	}
	return result, nil
}

type inspectItem struct {
	Resources struct {
		CPUs     int `json:"CPUs"`
		Memory   int `json:"Memory"`
		DiskSize int `json:"DiskSize"`
	} `json:"Resources"`
	State string `json:"State"`
}

func decodeInspect(data []byte) (machine.State, error) {
	var items []inspectItem
	if err := json.Unmarshal(data, &items); err != nil {
		return machine.State{}, fmt.Errorf("decode podman machine inspect: %w", err)
	}
	if len(items) != 1 {
		return machine.State{}, fmt.Errorf("podman machine inspect returned %d machines", len(items))
	}
	item := items[0]
	return machine.State{
		CPUs:      item.Resources.CPUs,
		MemoryMiB: item.Resources.Memory,
		DiskGiB:   item.Resources.DiskSize,
		Status:    item.State,
	}, nil
}
