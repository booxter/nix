package controller

import (
	"reflect"
	"testing"
)

func TestClassifyMediaFilesAcceptsSupportedWantedFiles(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		path      []string
		extension MediaExtension
	}{
		{name: "transport stream", path: []string{"Movie-part1.ts"}, extension: MediaExtensionTS},
		{name: "MP4 case insensitive", path: []string{"Movie-part2.MP4"}, extension: MediaExtensionMP4},
		{name: "Matroska", path: []string{"Movie-part3.mkv"}, extension: MediaExtensionMKV},
		{name: "AVI", path: []string{"Movie-part4.avi"}, extension: MediaExtensionAVI},
		{name: "nested bonus video", path: []string{"bonus", "Stuff.mp4"}, extension: MediaExtensionMP4},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			file := completeInventoryFile("file:one", test.path)
			assessment := ClassifyMediaFiles(FileInventory{Files: []InventoryFile{file}})[0]
			if !assessment.ProbeCandidate() {
				t.Fatalf("disposition = %q, reason = %q", assessment.Disposition, assessment.ExclusionReason)
			}
			if assessment.Extension != test.extension {
				t.Fatalf("extension = %q, want %q", assessment.Extension, test.extension)
			}
			if assessment.ExclusionReason != "" {
				t.Fatalf("exclusion reason = %q", assessment.ExclusionReason)
			}
			if !reflect.DeepEqual(assessment.File, file) {
				t.Fatalf("file changed: %#v", assessment.File)
			}
		})
	}
}

func TestClassifyMediaFilesRetainsExcludedFilesAsEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*InventoryFile)
		want   MediaFileExclusionReason
	}{
		{
			name: "untracked",
			mutate: func(file *InventoryFile) {
				file.TorrentFile = nil
			},
			want: MediaFileUntracked,
		},
		{
			name: "unwanted",
			mutate: func(file *InventoryFile) {
				file.TorrentFile.Wanted = false
			},
			want: MediaFileUnwanted,
		},
		{
			name: "incomplete",
			mutate: func(file *InventoryFile) {
				file.TorrentFile.BytesCompleted--
			},
			want: MediaFileIncomplete,
		},
		{
			name: "empty",
			mutate: func(file *InventoryFile) {
				file.Fingerprint.SizeBytes = 0
				file.TorrentFile.LengthBytes = 0
				file.TorrentFile.BytesCompleted = 0
			},
			want: MediaFileEmpty,
		},
		{
			name: "Radarr extension outside repair v1",
			mutate: func(file *InventoryFile) {
				file.PathComponents = []string{"Movie.mov"}
			},
			want: MediaFileUnsupportedExtension,
		},
		{
			name: "missing path",
			mutate: func(file *InventoryFile) {
				file.PathComponents = nil
			},
			want: MediaFileUnsupportedExtension,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			file := completeInventoryFile("file:one", []string{"Movie.mkv"})
			test.mutate(&file)
			assessment := ClassifyMediaFiles(FileInventory{Files: []InventoryFile{file}})[0]
			if assessment.ProbeCandidate() {
				t.Fatal("file was a probe candidate")
			}
			if assessment.Disposition != MediaFileEvidenceOnly {
				t.Fatalf("disposition = %q", assessment.Disposition)
			}
			if assessment.ExclusionReason != test.want {
				t.Fatalf("exclusion reason = %q, want %q", assessment.ExclusionReason, test.want)
			}
			if assessment.Extension != "" {
				t.Fatalf("extension = %q", assessment.Extension)
			}
			if !reflect.DeepEqual(assessment.File, file) {
				t.Fatalf("file changed: %#v", assessment.File)
			}
		})
	}
}

func TestClassifyMediaFilesPreservesInventoryOrder(t *testing.T) {
	t.Parallel()

	first := completeInventoryFile("file:first", []string{"Movie-part1.mkv"})
	second := completeInventoryFile("file:second", []string{"README.txt"})
	second.TorrentFile = nil
	third := completeInventoryFile("file:third", []string{"Movie-part2.mkv"})

	assessments := ClassifyMediaFiles(FileInventory{Files: []InventoryFile{first, second, third}})
	wantIDs := []FileID{"file:first", "file:second", "file:third"}
	if len(assessments) != len(wantIDs) {
		t.Fatalf("assessments = %d", len(assessments))
	}
	for index, wantID := range wantIDs {
		if assessments[index].File.ID != wantID {
			t.Fatalf("assessment %d file ID = %q, want %q", index, assessments[index].File.ID, wantID)
		}
	}
	if !assessments[0].ProbeCandidate() || assessments[1].ProbeCandidate() || !assessments[2].ProbeCandidate() {
		t.Fatalf("assessment dispositions = %#v", assessments)
	}
}

func completeInventoryFile(id FileID, pathComponents []string) InventoryFile {
	return InventoryFile{
		ID:             id,
		PathComponents: pathComponents,
		Fingerprint: FileFingerprint{
			SizeBytes: 100,
		},
		TorrentFile: &TorrentFileReference{
			Index:          0,
			LengthBytes:    100,
			BytesCompleted: 100,
			Wanted:         true,
		},
	}
}
