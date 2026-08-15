package networkrates

import (
	"errors"
	"reflect"
	"testing"
	"time"
)

type fakeProvider struct {
	rates Rates
	err   error
}

func (provider fakeProvider) Rates(Config, time.Time) (Rates, error) {
	return provider.rates, provider.err
}

type recordingBar struct {
	calls [][]string
	err   error
}

func (bar *recordingBar) Run(arguments ...string) error {
	bar.calls = append(bar.calls, append([]string(nil), arguments...))
	return bar.err
}

func TestFormatRateUsesBinaryUnits(t *testing.T) {
	cases := map[float64]string{
		-1:         "0B",
		0:          "0B",
		1023.6:     "1024B",
		1024:       "1.0K",
		1536:       "1.5K",
		2621440:    "2.5M",
		1073741824: "1.0G",
	}
	for value, want := range cases {
		if got := FormatRate(value); got != want {
			t.Errorf("FormatRate(%v) = %q, want %q", value, got, want)
		}
	}
}

func TestRunRendersRatesAndFallsBackToZero(t *testing.T) {
	cases := map[string]struct {
		provider fakeProvider
		down     string
		up       string
	}{
		"rates": {provider: fakeProvider{rates: Rates{Down: 1536, Up: 2621440}}, down: "1.5K", up: "2.5M"},
		"error": {provider: fakeProvider{err: errors.New("stale")}, down: "0B", up: "0B"},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			bar := &recordingBar{}
			if err := Run(Config{}, test.provider, bar, time.Time{}); err != nil {
				t.Fatalf("Run returned an error: %v", err)
			}
			want := [][]string{{
				"-m", "--set", "network.down", "label=" + test.down,
				"--set", "network.up", "label=" + test.up,
			}}
			if !reflect.DeepEqual(bar.calls, want) {
				t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
			}
		})
	}
}

func TestRunPropagatesSketchybarFailure(t *testing.T) {
	bar := &recordingBar{err: errors.New("bar failed")}
	if err := Run(Config{}, fakeProvider{}, bar, time.Time{}); err == nil {
		t.Fatal("expected SketchyBar failure")
	}
}
