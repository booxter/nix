package controller

import (
	"context"

	"github.com/booxter/nix-config/media-repair/internal/fileidentity"
)

type FileInventoryReader interface {
	Inventory(context.Context, DownloadCorrelation) (FileInventory, error)
}

type FileID string

type FileFingerprint = fileidentity.Snapshot

type DownloadFileReference struct {
	Index          int
	HasIndex       bool
	LengthBytes    int64
	BytesCompleted int64
	Selected       bool
}

// InventoryFile contains relative identity and local metadata. Absolute paths
// remain in FileInventory.Paths for controller-local use.
type InventoryFile struct {
	ID             FileID
	PathComponents []string
	Fingerprint    FileFingerprint
	DownloadFile   *DownloadFileReference
}

type FilePathMapping struct {
	FileID       FileID
	AbsolutePath string
}

type FileInventory struct {
	Files []InventoryFile
	Paths []FilePathMapping
}
