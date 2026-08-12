package clock

import (
	"reflect"
	"testing"
	"time"
)

type recordingBar struct {
	calls [][]string
}

func (bar *recordingBar) Run(arguments ...string) error {
	bar.calls = append(bar.calls, append([]string(nil), arguments...))
	return nil
}

func TestRunFormatsClockLabel(t *testing.T) {
	bar := &recordingBar{}
	now := time.Date(2026, time.August, 3, 9, 7, 42, 0, time.UTC)
	if err := Run(Config{Name: "clock"}, now, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{"--set", "clock", "label=03/08 09:07"}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}
