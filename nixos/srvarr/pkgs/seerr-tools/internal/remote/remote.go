package remote

import (
	"context"
	"io"
	"os/exec"
	"strings"

	"al.essio.dev/pkg/shellescape"
)

type Runner interface {
	Run(ctx context.Context, name string, args ...string) error
}

type ExecRunner struct {
	Stdout io.Writer
	Stderr io.Writer
}

func (runner ExecRunner) Run(ctx context.Context, name string, args ...string) error {
	command := exec.CommandContext(ctx, name, args...)
	command.Stdout = runner.Stdout
	command.Stderr = runner.Stderr
	return command.Run()
}

func Run(
	ctx context.Context,
	runner Runner,
	host string,
	program string,
	arguments []string,
) error {
	remoteArguments := []string{
		"sudo",
		"-n",
		"--user=seerr",
		"--",
		"/run/current-system/sw/bin/" + program,
		"--local",
	}
	remoteArguments = append(remoteArguments, arguments...)
	quoted := make([]string, len(remoteArguments))
	for index, argument := range remoteArguments {
		quoted[index] = shellescape.Quote(argument)
	}
	// OpenSSH accepts the remote command as one string and has the remote login
	// shell parse it. Quote each argv element at that unavoidable boundary.
	return runner.Run(ctx, "ssh", "-T", host, strings.Join(quoted, " "))
}
