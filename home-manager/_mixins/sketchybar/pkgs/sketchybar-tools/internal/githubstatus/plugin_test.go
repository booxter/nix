package githubstatus

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type fakeFetcher struct {
	summary Summary
	err     error
}

func (fetcher fakeFetcher) Fetch(context.Context) (Summary, error) {
	return fetcher.summary, fetcher.err
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
		Name:                 "github-status",
		URL:                  "https://github-status.test/api/v2/summary.json",
		Red:                  defaultRed,
		SketchybarExecutable: "/sketchybar",
	}
}

func TestRunHidesItemWhenGitHubIsOperational(t *testing.T) {
	bar := &recordingBar{}
	fetcher := fakeFetcher{summary: Summary{
		Indicator:  "none",
		Components: []Component{{Status: "operational"}},
	}}
	if err := Run(context.Background(), testConfig(), fetcher, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{"--set", "github-status", "drawing=off"}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunShowsGitHubIconForIssues(t *testing.T) {
	bar := &recordingBar{}
	fetcher := fakeFetcher{summary: Summary{Indicator: "minor"}}
	if err := Run(context.Background(), testConfig(), fetcher, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{
		"--set", "github-status", "drawing=on", "icon=",
		"icon.color=" + defaultRed, "label.drawing=off",
	}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunPreservesLastStateWhenStatusIsUnavailable(t *testing.T) {
	bar := &recordingBar{}
	fetcher := fakeFetcher{err: errors.New("unavailable")}
	if err := Run(context.Background(), testConfig(), fetcher, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	if len(bar.calls) != 0 {
		t.Fatalf("unexpected SketchyBar calls: %#v", bar.calls)
	}
}

func TestRunPropagatesSketchybarFailure(t *testing.T) {
	bar := &recordingBar{err: errors.New("bar failed")}
	fetcher := fakeFetcher{summary: Summary{Indicator: "none"}}
	if err := Run(context.Background(), testConfig(), fetcher, bar); err == nil {
		t.Fatal("expected SketchyBar failure")
	}
}
