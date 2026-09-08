package controller

import (
	"reflect"
	"testing"
	"time"
)

func TestBindRadarrManualImportFile(t *testing.T) {
	t.Parallel()

	file, path, manualImport := manualImportBindingFixture()
	binding, ok := BindRadarrManualImportFile(file, path, manualImport, nil)
	if !ok {
		t.Fatal("complete manual import was not bound")
	}
	want := RadarrManualImportBinding{
		FileID:              file.ID,
		ExpectedFingerprint: file.Fingerprint,
		ImportMode:          RadarrImportModeCopy,
		File: RadarrManualImportCommandFile{
			Path:         path,
			FolderName:   "Example.Movie.2026",
			Quality:      *manualImport.Quality,
			Languages:    []RadarrLanguage{{ID: 1, Name: "English"}},
			ReleaseGroup: "GROUP",
			IndexerFlags: 4,
			DownloadID:   "ABCDEF0123456789",
			MovieID:      42,
		},
	}
	if !reflect.DeepEqual(binding, want) {
		t.Fatalf("binding = %#v, want %#v", binding, want)
	}

	manualImport.Quality.Quality.Name = "changed"
	manualImport.Quality.Revision.Version = 99
	manualImport.Languages[0].Name = "changed"
	if binding.File.Quality.Quality.Name != "Bluray-1080p" ||
		binding.File.Quality.Revision.Version != 2 ||
		binding.File.Languages[0].Name != "English" {
		t.Fatalf("binding changed with its input: %#v", binding)
	}
}

func TestBindRadarrManualImportFileUsesLatestGrabMetadata(t *testing.T) {
	t.Parallel()

	file, path, manualImport := manualImportBindingFixture()
	manualImport.Quality = nil
	manualImport.Languages = nil
	olderQuality := bindingQuality(3, "WEBDL-1080p")
	newerQuality := bindingQuality(7, "Bluray-1080p")
	history := []RadarrHistoryEvent{
		{
			ID: 10, MovieID: 42, DownloadID: "abcdef0123456789",
			EventType:  RadarrHistoryEventGrabbed,
			OccurredAt: time.Date(2026, 9, 6, 12, 0, 0, 0, time.UTC),
			Quality:    olderQuality,
			Languages:  []RadarrLanguage{{ID: 2, Name: "French"}},
		},
		{
			ID: 11, MovieID: 42, DownloadID: "ABCDEF0123456789",
			EventType:  RadarrHistoryEventGrabbed,
			OccurredAt: time.Date(2026, 9, 6, 13, 0, 0, 0, time.UTC),
			Quality:    newerQuality,
			Languages:  []RadarrLanguage{{ID: 1, Name: "English"}},
		},
	}

	binding, ok := BindRadarrManualImportFile(file, path, manualImport, history)
	if !ok {
		t.Fatal("manual import was not completed from grab history")
	}
	if !reflect.DeepEqual(binding.File.Quality, *newerQuality) ||
		!reflect.DeepEqual(binding.File.Languages, history[1].Languages) {
		t.Fatalf("bound metadata = %#v", binding.File)
	}
}

func TestBindRadarrManualImportFileAllowsEmptyOptionalMetadata(t *testing.T) {
	t.Parallel()

	file, path, manualImport := manualImportBindingFixture()
	manualImport.Languages = nil
	manualImport.ReleaseGroup = ""

	binding, ok := BindRadarrManualImportFile(file, path, manualImport, nil)
	if !ok {
		t.Fatal("empty optional metadata prevented binding")
	}
	if binding.File.Languages == nil || len(binding.File.Languages) != 0 ||
		binding.File.ReleaseGroup != "" {
		t.Fatalf("optional metadata = %#v", binding.File)
	}
}

func TestBindRadarrManualImportFileRejectsIncompleteBindings(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*InventoryFile, *string, *RadarrManualImport)
	}{
		{
			name: "missing file ID",
			mutate: func(file *InventoryFile, _ *string, _ *RadarrManualImport) {
				file.ID = ""
			},
		},
		{
			name: "unwanted torrent file",
			mutate: func(file *InventoryFile, _ *string, _ *RadarrManualImport) {
				file.TorrentFile.Wanted = false
			},
		},
		{
			name: "incomplete torrent file",
			mutate: func(file *InventoryFile, _ *string, _ *RadarrManualImport) {
				file.TorrentFile.BytesCompleted--
			},
		},
		{
			name: "unsupported extension",
			mutate: func(file *InventoryFile, _ *string, _ *RadarrManualImport) {
				file.PathComponents = []string{"Movie.txt"}
			},
		},
		{
			name: "raw disc tree",
			mutate: func(file *InventoryFile, _ *string, _ *RadarrManualImport) {
				file.PathComponents = []string{"BDMV", "STREAM", "00000.m2ts"}
			},
		},
		{
			name: "path mismatch",
			mutate: func(_ *InventoryFile, path *string, _ *RadarrManualImport) {
				*path += ".different"
			},
		},
		{
			name: "size mismatch",
			mutate: func(_ *InventoryFile, _ *string, manualImport *RadarrManualImport) {
				manualImport.SizeBytes++
			},
		},
		{
			name: "missing movie ID",
			mutate: func(_ *InventoryFile, _ *string, manualImport *RadarrManualImport) {
				manualImport.MovieID = 0
			},
		},
		{
			name: "missing folder name",
			mutate: func(_ *InventoryFile, _ *string, manualImport *RadarrManualImport) {
				manualImport.FolderName = ""
			},
		},
		{
			name: "missing download ID",
			mutate: func(_ *InventoryFile, _ *string, manualImport *RadarrManualImport) {
				manualImport.DownloadID = ""
			},
		},
		{
			name: "missing quality",
			mutate: func(_ *InventoryFile, _ *string, manualImport *RadarrManualImport) {
				manualImport.Quality = nil
			},
		},
		{
			name: "invalid release group",
			mutate: func(_ *InventoryFile, _ *string, manualImport *RadarrManualImport) {
				manualImport.ReleaseGroup = " "
			},
		},
		{
			name: "invalid language",
			mutate: func(_ *InventoryFile, _ *string, manualImport *RadarrManualImport) {
				manualImport.Languages[0].Name = " "
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			file, path, manualImport := manualImportBindingFixture()
			test.mutate(&file, &path, &manualImport)
			if binding, ok := BindRadarrManualImportFile(file, path, manualImport, nil); ok {
				t.Fatalf("incomplete input produced binding %#v", binding)
			}
		})
	}
}

func manualImportBindingFixture() (InventoryFile, string, RadarrManualImport) {
	file := completeInventoryFile("file:one", []string{"Example.Movie.2026.mkv"})
	file.Fingerprint = FileFingerprint{Device: 1, Inode: 2, SizeBytes: 100, MTimeNS: 3}
	path := "/downloads/Example.Movie.2026/Example.Movie.2026.mkv"
	return file, path, RadarrManualImport{
		Path:         path,
		RelativePath: "Example.Movie.2026.mkv",
		FolderName:   "Example.Movie.2026",
		SizeBytes:    100,
		MovieID:      42,
		DownloadID:   "ABCDEF0123456789",
		Quality:      bindingQuality(7, "Bluray-1080p"),
		Languages:    []RadarrLanguage{{ID: 1, Name: "English"}},
		ReleaseGroup: "GROUP",
		IndexerFlags: 4,
		Rejections: []RadarrManualImportRejection{{
			Type: "permanent", Reason: "Unable to parse file",
		}},
	}
}

func bindingQuality(id int64, name string) *RadarrQualityModel {
	return &RadarrQualityModel{
		Quality: RadarrQuality{
			ID: id, Name: name, Source: "bluray", Resolution: 1080, Modifier: "none",
		},
		Revision: &RadarrQualityRevision{Version: 2, Real: 1, IsRepack: true},
	}
}
