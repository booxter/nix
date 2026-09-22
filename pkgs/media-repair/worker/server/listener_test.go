package workerserver

import (
	"os"
	"path/filepath"
	"testing"
)

func TestListenUnixCreatesAndRemovesRestrictedSocket(t *testing.T) {
	t.Parallel()

	socketPath := filepath.Join(t.TempDir(), "worker.sock")
	listener, err := ListenUnix(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Type() != os.ModeSocket || info.Mode().Perm() != SocketMode {
		t.Fatalf("socket mode = %v", info.Mode())
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("socket remains after close: %v", err)
	}
}

func TestListenUnixRefusesExistingEntry(t *testing.T) {
	t.Parallel()

	socketPath := filepath.Join(t.TempDir(), "worker.sock")
	if err := os.WriteFile(socketPath, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ListenUnix(socketPath); err == nil {
		t.Fatal("existing socket path was accepted")
	}
	data, err := os.ReadFile(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "keep" {
		t.Fatalf("existing entry changed to %q", data)
	}
}

func TestListenUnixRejectsInvalidPath(t *testing.T) {
	t.Parallel()

	for _, socketPath := range []string{"", "relative.sock", "/tmp/../tmp/worker.sock"} {
		if _, err := ListenUnix(socketPath); err == nil {
			t.Fatalf("socket path %q was accepted", socketPath)
		}
	}
}
