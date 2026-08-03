package alertmanager

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type fakeCounter struct {
	count int
	err   error
}

func (counter fakeCounter) Count(context.Context) (int, error) {
	return counter.count, counter.err
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
		Name:                 "alertmanager",
		URL:                  "https://alertmanager.test/api/v2/alerts",
		CACertificate:        "/ca",
		ClientCertificate:    "/cert",
		ClientKey:            "/key",
		Red:                  defaultRed,
		Yellow:               defaultYellow,
		SketchybarExecutable: "/sketchybar",
	}
}

func TestRunHidesItemWithoutFiringAlerts(t *testing.T) {
	bar := &recordingBar{}
	if err := Run(context.Background(), testConfig(), fakeCounter{}, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{"--set", "alertmanager", "drawing=off"}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunShowsFiringAlertCount(t *testing.T) {
	bar := &recordingBar{}
	if err := Run(context.Background(), testConfig(), fakeCounter{count: 2}, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{
		"--set", "alertmanager", "drawing=on", "icon=!",
		"icon.color=" + defaultRed, "label=2", "label.color=" + defaultRed,
	}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunShowsErrorStateWhenAlertmanagerIsUnavailable(t *testing.T) {
	bar := &recordingBar{}
	err := Run(
		context.Background(),
		testConfig(),
		fakeCounter{err: errors.New("unavailable")},
		bar,
	)
	if err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{
		"--set", "alertmanager", "drawing=on", "icon=!",
		"icon.color=" + defaultYellow, "label=?", "label.color=" + defaultYellow,
	}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunPropagatesSketchybarFailure(t *testing.T) {
	bar := &recordingBar{err: errors.New("bar failed")}
	if err := Run(context.Background(), testConfig(), fakeCounter{}, bar); err == nil {
		t.Fatal("expected SketchyBar failure")
	}
}
