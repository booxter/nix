package mkvmerge

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/controller"
)

const (
	minimumFeatureMS = 20 * 60 * 1000
	maximumPlaylists = 128
)

type Candidate struct {
	PlaylistFileID controller.FileID
	ClipFileIDs    []controller.FileID
	Details        Playlist
}

// ListFeaturePlaylists keeps only playlists whose referenced clips belong to
// this completed download. It does not choose a title.
func ListFeaturePlaylists(
	ctx context.Context,
	inventory controller.FileInventory,
	identifier Identifier,
) ([]Candidate, error) {
	if identifier == nil {
		return nil, fmt.Errorf("playlist identifier is required")
	}
	files, paths, err := inventoryIndex(inventory)
	if err != nil {
		return nil, err
	}

	playlists := playlistFiles(files)
	if len(playlists) > maximumPlaylists {
		return nil, fmt.Errorf("download has more than %d Blu-ray playlists", maximumPlaylists)
	}
	candidates := make([]Candidate, 0, len(playlists))
	for _, file := range playlists {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if !available(file) {
			continue
		}
		path := paths[file.ID]
		details, err := identifier.Identify(ctx, Target{
			Path: path, ExpectedFingerprint: file.Fingerprint.Fingerprint(),
		})
		if err != nil {
			return nil, fmt.Errorf("identify %q: %w", path, err)
		}
		if details.DurationMS < minimumFeatureMS {
			continue
		}
		clipIDs, ok := inventoryClips(path, details.ClipPaths, files)
		if !ok {
			continue
		}
		candidates = append(candidates, Candidate{
			PlaylistFileID: file.ID,
			ClipFileIDs:    clipIDs,
			Details:        details,
		})
	}
	return candidates, nil
}

func inventoryIndex(
	inventory controller.FileInventory,
) (map[string]controller.InventoryFile, map[controller.FileID]string, error) {
	paths := make(map[controller.FileID]string, len(inventory.Paths))
	for _, mapping := range inventory.Paths {
		if _, duplicate := paths[mapping.FileID]; duplicate {
			return nil, nil, fmt.Errorf("duplicate inventory file ID %q", mapping.FileID)
		}
		paths[mapping.FileID] = mapping.AbsolutePath
	}
	files := make(map[string]controller.InventoryFile, len(inventory.Files))
	for _, file := range inventory.Files {
		path, exists := paths[file.ID]
		if !exists || !cleanAbsolute(path) {
			return nil, nil, fmt.Errorf("inventory file %q has no clean absolute path", file.ID)
		}
		if _, duplicate := files[path]; duplicate {
			return nil, nil, fmt.Errorf("duplicate inventory path %q", path)
		}
		files[path] = file
	}
	if len(files) != len(paths) {
		return nil, nil, fmt.Errorf("inventory files and paths differ")
	}
	return files, paths, nil
}

func playlistFiles(files map[string]controller.InventoryFile) []controller.InventoryFile {
	playlists := make([]controller.InventoryFile, 0)
	for _, file := range files {
		parts := file.PathComponents
		if len(parts) < 3 {
			continue
		}
		if parts[len(parts)-3] != "BDMV" || parts[len(parts)-2] != "PLAYLIST" ||
			!NumberedPlaylist(parts[len(parts)-1]) {
			continue
		}
		playlists = append(playlists, file)
	}
	sort.Slice(playlists, func(i, j int) bool {
		return strings.Join(playlists[i].PathComponents, "/") <
			strings.Join(playlists[j].PathComponents, "/")
	})
	return playlists
}

func NumberedPlaylist(name string) bool {
	return numberedFile(name, ".mpls")
}

func NumberedClip(name string) bool {
	return numberedFile(name, ".m2ts")
}

func numberedFile(name, extension string) bool {
	if len(name) != 5+len(extension) || !strings.HasSuffix(name, extension) {
		return false
	}
	for _, digit := range name[:5] {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
}

func inventoryClips(
	playlistPath string,
	clipPaths []string,
	files map[string]controller.InventoryFile,
) ([]controller.FileID, bool) {
	streamDir := filepath.Join(filepath.Dir(filepath.Dir(playlistPath)), "STREAM")
	clipIDs := make([]controller.FileID, 0, len(clipPaths))
	for _, path := range clipPaths {
		if !cleanAbsolute(path) || filepath.Dir(path) != streamDir ||
			!NumberedClip(filepath.Base(path)) {
			return nil, false
		}
		file, exists := files[path]
		if !exists || !available(file) {
			return nil, false
		}
		clipIDs = append(clipIDs, file.ID)
	}
	return clipIDs, len(clipIDs) > 0
}

func available(file controller.InventoryFile) bool {
	if file.Fingerprint.SizeBytes <= 0 {
		return false
	}
	if file.DownloadFile == nil {
		return true
	}
	return file.DownloadFile.Selected &&
		file.DownloadFile.LengthBytes == file.Fingerprint.SizeBytes &&
		file.DownloadFile.BytesCompleted == file.Fingerprint.SizeBytes
}
