package workerclient

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/commanddiagnostics"
)

type RequestRunner interface {
	Run(context.Context, string, []byte, int) ([]byte, error)
}

type Process struct{ Executable string }

func NewProcess(executable string, roots map[string]string, timeout, mediaTimeout time.Duration) (*Client, error) {
	client, err := newClient(roots, timeout, mediaTimeout)
	if err != nil {
		return nil, err
	}
	client.runner = Process{Executable: executable}
	return client, nil
}

func (process Process) Run(ctx context.Context, operation string, input []byte, limit int) ([]byte, error) {
	command := exec.CommandContext(ctx, process.Executable, "--operation", operation)
	command.WaitDelay = 5 * time.Second
	command.Stdin = bytes.NewReader(input)
	output := boundedOutput{limit: limit}
	diagnostics := commanddiagnostics.NewRecorder()
	command.Stdout, command.Stderr = &output, diagnostics
	if err := command.Run(); err != nil {
		return nil, commanddiagnostics.Attach(fmt.Errorf("media helper %s: %w", operation, err), diagnostics.Diagnostics())
	}
	return output.Bytes(), nil
}

type boundedOutput struct {
	bytes.Buffer
	limit int
}

func (output *boundedOutput) Write(data []byte) (int, error) {
	if len(data) > output.limit-output.Len() {
		return 0, fmt.Errorf("media helper response exceeds %d bytes", output.limit)
	}
	return output.Buffer.Write(data)
}
