package materialize

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestValidateRARListing(t *testing.T) {
	t.Parallel()
	data := []byte(`{
		"lsarFormatVersion":2,
		"lsarContents":[
			{"XADFileName":"Album/","XADIsDirectory":true},
			{"XADFileName":"Album/01.flac","XADFileSize":123}
		],
		"lsarFormatName":"RAR 5"
	}`)
	if err := validateRARListing(data); err != nil {
		t.Fatal(err)
	}
}

func TestValidateRARListingRejectsUnsafeEntries(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		data string
		want error
	}{
		{
			name: "traversal",
			data: `{"lsarFormatVersion":2,"lsarContents":[{"XADFileName":"../01.flac","XADFileSize":1}]}`,
			want: errRARListing,
		},
		{
			name: "encrypted",
			data: `{"lsarFormatVersion":2,"lsarContents":[{"XADFileName":"01.flac","XADFileSize":1,"XADIsEncrypted":true}]}`,
			want: errRAREncrypted,
		},
		{
			name: "link",
			data: `{"lsarFormatVersion":2,"lsarContents":[{"XADFileName":"01.flac","XADFileSize":1,"XADIsLink":true}]}`,
			want: errRARListing,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := validateRARListing([]byte(test.data)); !errors.Is(err, test.want) {
				t.Fatalf("validateRARListing() error = %v, want %v", err, test.want)
			}
		})
	}
}

type fakeRARExtractor struct {
	err error
}

func (extractor fakeRARExtractor) Extract(
	_ context.Context,
	_ *os.File,
	destination string,
) error {
	if extractor.err != nil {
		return extractor.err
	}
	directory := filepath.Join(destination, "Album")
	if err := os.Mkdir(directory, 0o700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(directory, "01.flac"), []byte("audio"), 0o600)
}

func TestMaterializeRARAudio(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, workspaceDirectory), 0o750); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(root, "release.rar")
	if err := os.WriteFile(archive, []byte("rar"), 0o600); err != nil {
		t.Fatal(err)
	}
	probeWorkspaceSetup(t, root)
	prober := &fakeProber{}
	executor, err := NewExecutor(
		&fakeFiles{root: root, archive: archive}, prober, fakeRARExtractor{},
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request := validRequest()
	request.Operation = OperationMaterializeRAR
	request.SourceComponents = []string{"release.rar"}
	request.WorkspaceID = "workspace:rar"
	response := executor.ExecuteRAR(context.Background(), request)
	if response.Success == nil || response.Failure != nil ||
		response.Success.Operation != OperationMaterializeRAR ||
		len(response.Success.Artifacts) != 1 ||
		response.Success.Artifacts[0].RelativePath != "Album/01.flac" || len(prober.paths) != 1 {
		t.Fatalf("response = %#v, failure = %#v", response, response.Failure)
	}
	workspace := filepath.Join(root, workspaceDirectory, "workspaces", "workspace:rar")
	if _, err := os.Stat(filepath.Join(workspace, ".rar-extract")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("RAR quarantine remains: %v", err)
	}
}
