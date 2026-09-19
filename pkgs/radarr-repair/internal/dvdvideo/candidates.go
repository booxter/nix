package dvdvideo

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

const (
	minimumFeatureMS = 20 * 60 * 1000
	maximumDiscs     = 8
	maximumFiles     = 1024
)

type Candidate struct {
	NavigationFileID controller.FileID
	SourceFileIDs    []controller.FileID
	Details          Title
}

// ListFeatureTitles offers title navigation only when every inventoried file
// in the VIDEO_TS directory belongs to a complete, selected DVD structure.
func ListFeatureTitles(
	ctx context.Context, inventory controller.FileInventory, identifier Identifier,
) ([]Candidate, error) {
	if identifier == nil {
		return nil, fmt.Errorf("DVD title identifier is required")
	}
	paths := make(map[controller.FileID]string, len(inventory.Paths))
	for _, mapping := range inventory.Paths {
		if _, duplicate := paths[mapping.FileID]; duplicate ||
			!filepath.IsAbs(mapping.AbsolutePath) ||
			filepath.Clean(mapping.AbsolutePath) != mapping.AbsolutePath {
			return nil, fmt.Errorf("DVD inventory has an invalid file path")
		}
		paths[mapping.FileID] = mapping.AbsolutePath
	}
	if len(paths) != len(inventory.Files) {
		return nil, fmt.Errorf("DVD inventory paths and files differ")
	}
	var navigation []controller.InventoryFile
	for _, file := range inventory.Files {
		parts := file.PathComponents
		if len(parts) >= 2 && parts[len(parts)-2] == "VIDEO_TS" &&
			parts[len(parts)-1] == "VIDEO_TS.IFO" {
			navigation = append(navigation, file)
		}
	}
	if len(navigation) > maximumDiscs {
		return nil, fmt.Errorf("download contains too many DVD structures")
	}
	sort.Slice(navigation, func(left, right int) bool {
		return paths[navigation[left].ID] < paths[navigation[right].ID]
	})
	var candidates []Candidate
	for _, navigationFile := range navigation {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if !available(navigationFile) {
			continue
		}
		path := paths[navigationFile.ID]
		if path == "" || filepath.Base(path) != "VIDEO_TS.IFO" ||
			filepath.Base(filepath.Dir(path)) != "VIDEO_TS" {
			return nil, fmt.Errorf("DVD navigation file path differs from inventory")
		}
		files, complete := discFiles(inventory.Files, paths, filepath.Dir(path))
		if !complete {
			continue
		}
		titles, err := identifier.IdentifyDVD(ctx, Target{
			NavigationPath:      path,
			ExpectedFingerprint: navigationFile.Fingerprint.Fingerprint(),
		})
		if err != nil {
			return nil, fmt.Errorf("identify DVD %q: %w", path, err)
		}
		for _, title := range titles {
			if title.DurationMS < minimumFeatureMS || title.Angles != 1 ||
				!hasTitleFiles(files, title.TitleSet) || !hasMovieTracks(title.Tracks) {
				continue
			}
			fileIDs := make([]controller.FileID, 0, len(files))
			for _, file := range files {
				fileIDs = append(fileIDs, file.ID)
			}
			candidates = append(candidates, Candidate{
				NavigationFileID: navigationFile.ID,
				SourceFileIDs:    fileIDs,
				Details:          title,
			})
		}
	}
	return candidates, nil
}

func discFiles(
	inventory []controller.InventoryFile,
	paths map[controller.FileID]string,
	directory string,
) ([]controller.InventoryFile, bool) {
	files := make([]controller.InventoryFile, 0)
	for _, file := range inventory {
		path := paths[file.ID]
		if filepath.Dir(path) != directory {
			continue
		}
		if !validDVDFileName(filepath.Base(path)) || !available(file) {
			return nil, false
		}
		files = append(files, file)
	}
	if len(files) < 3 || len(files) > maximumFiles {
		return nil, false
	}
	sort.Slice(files, func(left, right int) bool {
		return paths[files[left].ID] < paths[files[right].ID]
	})
	return files, true
}

func validDVDFileName(name string) bool {
	switch name {
	case "VIDEO_TS.IFO", "VIDEO_TS.BUP", "VIDEO_TS.VOB":
		return true
	}
	if !strings.HasPrefix(name, "VTS_") || len(name) != len("VTS_01_1.VOB") ||
		name[4] < '0' || name[4] > '9' || name[5] < '0' || name[5] > '9' ||
		name[6] != '_' || name[7] < '0' || name[7] > '9' {
		return false
	}
	return name[8:] == ".IFO" || name[8:] == ".BUP" || name[8:] == ".VOB"
}

func hasTitleFiles(files []controller.InventoryFile, titleSet int) bool {
	if titleSet < 1 || titleSet > 99 {
		return false
	}
	prefix := fmt.Sprintf("VTS_%02d_", titleSet)
	hasIFO, hasVOB := false, false
	for _, file := range files {
		name := file.PathComponents[len(file.PathComponents)-1]
		hasIFO = hasIFO || name == prefix+"0.IFO"
		hasVOB = hasVOB || name == prefix+"1.VOB"
	}
	return hasIFO && hasVOB
}

func hasMovieTracks(tracks []Track) bool {
	video, audio := false, false
	for _, track := range tracks {
		video = video || track.Kind == "video"
		audio = audio || track.Kind == "audio"
	}
	return video && audio
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
