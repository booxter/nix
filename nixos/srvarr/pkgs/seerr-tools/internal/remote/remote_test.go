package remote_test

import (
	"context"
	"reflect"
	"testing"

	"github.com/booxter/nix-config/seerr-tools/internal/remote"
)

type recordingRunner struct {
	name string
	args []string
}

func (runner *recordingRunner) Run(_ context.Context, name string, args ...string) error {
	runner.name = name
	runner.args = args
	return nil
}

func TestRunQuotesTheSingleOpenSSHCommand(t *testing.T) {
	runner := &recordingRunner{}
	err := remote.Run(
		context.Background(),
		runner,
		"srvarr",
		"seerr-request-storage",
		[]string{"--api-key-file", "/path with spaces/settings.json"},
	)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"-T",
		"srvarr",
		"sudo -n --user=seerr -- /run/current-system/sw/bin/seerr-request-storage --local --api-key-file '/path with spaces/settings.json'",
	}
	if runner.name != "ssh" || !reflect.DeepEqual(runner.args, want) {
		t.Fatalf("Run() = %q %#v", runner.name, runner.args)
	}
}
