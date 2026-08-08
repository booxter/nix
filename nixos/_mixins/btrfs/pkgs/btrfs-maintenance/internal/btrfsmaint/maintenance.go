//go:build linux

package btrfsmaint

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

type ExitStatusError struct {
	Code   int
	Output string
}

func (err ExitStatusError) Error() string {
	if err.Output == "" {
		return fmt.Sprintf("btrfs exited with status %d", err.Code)
	}
	return fmt.Sprintf("btrfs exited with status %d: %s", err.Code, err.Output)
}

type Operations interface {
	SubvolumeExists(context.Context, string) (bool, error)
	CreateSubvolume(context.Context, string) error
	Chmod(string, os.FileMode) error
	ResumeScrub(context.Context, string) error
	StartScrub(context.Context, string) error
	ScrubStatus(context.Context, string) (string, error)
}

func EnsureSubvolume(ctx context.Context, operations Operations, path string, mode os.FileMode) error {
	exists, err := operations.SubvolumeExists(ctx, path)
	if err != nil {
		return err
	}
	if !exists {
		if err := operations.CreateSubvolume(ctx, path); err != nil {
			return err
		}
	}
	if err := operations.Chmod(path, mode); err != nil {
		return fmt.Errorf("set subvolume mode: %w", err)
	}
	return nil
}

func StartOrResumeScrub(ctx context.Context, operations Operations, mount string) error {
	err := operations.ResumeScrub(ctx, mount)
	if err == nil {
		return nil
	}
	var exitStatus ExitStatusError
	if !errors.As(err, &exitStatus) || exitStatus.Code != 2 {
		return fmt.Errorf("resume scrub: %w", err)
	}
	if err := operations.StartScrub(ctx, mount); err != nil {
		return fmt.Errorf("start scrub: %w", err)
	}
	return nil
}

func ResumeInterruptedScrub(ctx context.Context, operations Operations, mount string) error {
	status, err := operations.ScrubStatus(ctx, mount)
	if err != nil {
		return err
	}
	if !isInterrupted(status) {
		return nil
	}
	if err := operations.ResumeScrub(ctx, mount); err != nil {
		return fmt.Errorf("resume interrupted scrub: %w", err)
	}
	return nil
}

func isInterrupted(output string) bool {
	for line := range strings.Lines(output) {
		label, value, found := strings.Cut(line, ":")
		if !found || strings.TrimSpace(label) != "Status" {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "interrupted", "cancelled", "canceled":
			return true
		default:
			return false
		}
	}
	return false
}

type CLI struct {
	Executable string
	Stdout     io.Writer
	Stderr     io.Writer
}

func (client CLI) run(ctx context.Context, arguments ...string) (string, error) {
	command := exec.CommandContext(ctx, client.Executable, arguments...)
	var stdout bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = client.Stderr
	err := command.Run()
	if err == nil {
		return stdout.String(), nil
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return stdout.String(), ExitStatusError{Code: exitError.ExitCode(), Output: strings.TrimSpace(stdout.String())}
	}
	return stdout.String(), err
}

func (client CLI) writeOutput(output string) {
	if client.Stdout != nil {
		_, _ = io.WriteString(client.Stdout, output)
	}
}

func (client CLI) SubvolumeExists(ctx context.Context, path string) (bool, error) {
	_, err := client.run(ctx, "subvolume", "show", path)
	if err == nil {
		return true, nil
	}
	var exitStatus ExitStatusError
	if errors.As(err, &exitStatus) {
		return false, nil
	}
	return false, fmt.Errorf("inspect subvolume: %w", err)
}

func (client CLI) CreateSubvolume(ctx context.Context, path string) error {
	output, err := client.run(ctx, "subvolume", "create", path)
	client.writeOutput(output)
	return err
}

func (client CLI) Chmod(path string, mode os.FileMode) error {
	return os.Chmod(path, mode)
}

func (client CLI) ResumeScrub(ctx context.Context, mount string) error {
	output, err := client.run(ctx, "scrub", "resume", "-B", mount)
	client.writeOutput(output)
	return err
}

func (client CLI) StartScrub(ctx context.Context, mount string) error {
	output, err := client.run(ctx, "scrub", "start", "-B", mount)
	client.writeOutput(output)
	return err
}

func (client CLI) ScrubStatus(ctx context.Context, mount string) (string, error) {
	output, err := client.run(ctx, "scrub", "status", mount)
	var exitStatus ExitStatusError
	if errors.As(err, &exitStatus) {
		return output, nil
	}
	if err != nil {
		return "", fmt.Errorf("read scrub status: %w", err)
	}
	return output, nil
}
