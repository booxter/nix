package workerserver

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
)

const SocketMode os.FileMode = 0o660

func ListenUnix(socketPath string) (*net.UnixListener, error) {
	if socketPath == "" || strings.ContainsRune(socketPath, '\x00') ||
		!filepath.IsAbs(socketPath) || filepath.Clean(socketPath) != socketPath {
		return nil, fmt.Errorf("worker socket must be an absolute clean path")
	}
	parent, err := os.Stat(filepath.Dir(socketPath))
	if err != nil {
		return nil, fmt.Errorf("inspect worker socket directory: %w", err)
	}
	if !parent.IsDir() {
		return nil, fmt.Errorf("worker socket parent is not a directory")
	}
	if _, err := os.Lstat(socketPath); err == nil {
		return nil, fmt.Errorf("worker socket path already exists")
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("inspect worker socket path: %w", err)
	}

	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("listen on worker socket: %w", err)
	}
	listener.SetUnlinkOnClose(true)
	if err := os.Chmod(socketPath, SocketMode); err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("set worker socket permissions: %w", err)
	}
	return listener, nil
}
