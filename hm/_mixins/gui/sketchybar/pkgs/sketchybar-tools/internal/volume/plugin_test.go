package volume

import (
	"reflect"
	"testing"
)

type recordingBar struct {
	calls [][]string
}

func (bar *recordingBar) Run(arguments ...string) error {
	bar.calls = append(bar.calls, append([]string(nil), arguments...))
	return nil
}

func TestRunMapsVolumeToIcons(t *testing.T) {
	for rawVolume, wantIcon := range map[string]string{
		"100": "󰕾",
		"60":  "󰕾",
		"59":  "󰖀",
		"30":  "󰖀",
		"29":  "󰕿",
		"1":   "󰕿",
		"0":   "󰖁",
		"101": "󰖁",
		"bad": "󰖁",
	} {
		t.Run(rawVolume, func(t *testing.T) {
			bar := &recordingBar{}
			err := Run(Config{
				Name:   "volume",
				Sender: volumeChangeSender,
				Volume: rawVolume,
			}, bar)
			if err != nil {
				t.Fatalf("Run returned an error: %v", err)
			}
			want := [][]string{{
				"--set", "volume", "icon=" + wantIcon, "label=" + rawVolume + "%",
			}}
			if !reflect.DeepEqual(bar.calls, want) {
				t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
			}
		})
	}
}

func TestRunIgnoresOtherEvents(t *testing.T) {
	bar := &recordingBar{}
	if err := Run(Config{Sender: "forced"}, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	if len(bar.calls) != 0 {
		t.Fatalf("unexpected SketchyBar calls: %#v", bar.calls)
	}
}
