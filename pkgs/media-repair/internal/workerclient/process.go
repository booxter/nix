package workerclient

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/commanddiagnostics"
)

type RequestRunner interface {
	Run(context.Context, string, []byte, int) ([]byte, error)
}

type Process struct {
	Executable   string
	ProbeTimeout time.Duration
	MediaTimeout time.Duration
}

// The worker owns execution deadlines; the client allows extra time for cleanup
// and delivery of the worker's diagnostics after a deadline expires.
func NewProcess(executable string, roots map[string]string, probeTimeout, mediaTimeout, responseGrace time.Duration) (*Client, error) {
	if probeTimeout <= 0 || mediaTimeout <= 0 || responseGrace <= 0 {
		return nil, fmt.Errorf("worker timeouts and response grace must be positive")
	}
	client, err := newClient(roots, probeTimeout+responseGrace, mediaTimeout+responseGrace)
	if err != nil {
		return nil, err
	}
	client.runner = Process{Executable: executable, ProbeTimeout: probeTimeout, MediaTimeout: mediaTimeout}
	return client, nil
}

func (process Process) Run(ctx context.Context, operation string, input []byte, limit int) ([]byte, error) {
	command := exec.CommandContext(ctx, process.Executable, "--operation", operation,
		"--timeout", process.ProbeTimeout.String(), "--media-timeout", process.MediaTimeout.String())
	command.WaitDelay = 5 * time.Second
	command.Stdin = bytes.NewReader(input)
	output := boundedOutput{limit: limit}
	diagnostics := commanddiagnostics.NewRecorder()
	command.Stdout, command.Stderr = &output, diagnostics
	if operation == "transform" {
		// Keep progress visible while the worker runs, including successful jobs.
		command.Stderr = io.MultiWriter(os.Stderr, diagnostics)
	}
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
