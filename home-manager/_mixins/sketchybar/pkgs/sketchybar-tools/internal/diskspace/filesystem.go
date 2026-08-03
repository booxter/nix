package diskspace

import (
	"fmt"
	"syscall"
)

type Usage struct {
	TotalBlocks     uint64
	AvailableBlocks uint64
}

type FileSystem interface {
	Usage(path string) (Usage, error)
}

type NativeFileSystem struct{}

func (NativeFileSystem) Usage(path string) (Usage, error) {
	var statistics syscall.Statfs_t
	if err := syscall.Statfs(path, &statistics); err != nil {
		return Usage{}, fmt.Errorf("read filesystem usage for %s: %w", path, err)
	}
	return Usage{
		TotalBlocks:     statistics.Blocks,
		AvailableBlocks: statistics.Bavail,
	}, nil
}
