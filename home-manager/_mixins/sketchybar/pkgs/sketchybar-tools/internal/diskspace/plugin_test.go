package diskspace

import (
	"errors"
	"reflect"
	"testing"
)

type fakeFileSystem struct {
	usage Usage
	err   error
	path  string
}

func (filesystem *fakeFileSystem) Usage(path string) (Usage, error) {
	filesystem.path = path
	return filesystem.usage, filesystem.err
}

type recordingBar struct {
	calls [][]string
	err   error
}

func (bar *recordingBar) Run(arguments ...string) error {
	bar.calls = append(bar.calls, append([]string(nil), arguments...))
	return bar.err
}

func testConfig() Config {
	return Config{
		Name:                 "disk",
		Home:                 "/Users/example",
		SketchybarExecutable: "/sketchybar",
	}
}

func TestRunShowsRoundedDownRemainingPercentage(t *testing.T) {
	filesystem := &fakeFileSystem{usage: Usage{TotalBlocks: 1000, AvailableBlocks: 169}}
	bar := &recordingBar{}
	if err := Run(testConfig(), filesystem, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	if filesystem.path != "/Users/example" {
		t.Errorf("filesystem path = %q, want /Users/example", filesystem.path)
	}
	want := [][]string{{"--set", "disk", "label=16%"}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunPreservesLastValueWhenUsageIsUnavailable(t *testing.T) {
	for name, filesystem := range map[string]*fakeFileSystem{
		"error":      {err: errors.New("unavailable")},
		"zero total": {usage: Usage{}},
	} {
		t.Run(name, func(t *testing.T) {
			bar := &recordingBar{}
			if err := Run(testConfig(), filesystem, bar); err != nil {
				t.Fatalf("Run returned an error: %v", err)
			}
			if len(bar.calls) != 0 {
				t.Fatalf("unexpected SketchyBar calls: %#v", bar.calls)
			}
		})
	}
}

func TestRunPropagatesSketchybarFailure(t *testing.T) {
	filesystem := &fakeFileSystem{usage: Usage{TotalBlocks: 1000, AvailableBlocks: 250}}
	bar := &recordingBar{err: errors.New("bar failed")}
	if err := Run(testConfig(), filesystem, bar); err == nil {
		t.Fatal("expected SketchyBar failure")
	}
}

func TestConfigFromEnvironmentValidatesSettings(t *testing.T) {
	values := map[string]string{
		"NAME":           "disk",
		"HOME":           "/Users/example",
		"SKETCHYBAR_BIN": "/sketchybar",
	}
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	delete(values, "HOME")
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err == nil {
		t.Fatal("missing home should fail")
	}
}
