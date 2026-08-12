package stock

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type fakeQuoteFetcher struct {
	quote Quote
	err   error
}

func (fetcher fakeQuoteFetcher) Fetch(context.Context) (Quote, error) {
	return fetcher.quote, fetcher.err
}

type recordingBar struct {
	calls [][]string
}

func (bar *recordingBar) Run(arguments ...string) error {
	bar.calls = append(bar.calls, append([]string(nil), arguments...))
	return nil
}

func testConfig() Config {
	return Config{
		Name:   "stock",
		Symbol: "NVDA",
		Green:  defaultGreen,
		Red:    defaultRed,
		Yellow: defaultYellow,
	}
}

func TestFormatPrice(t *testing.T) {
	for input, want := range map[string]string{
		"$1,234.5": "$1234.50",
		"42":       "42.00",
		" -2.5 ":   "-2.50",
		"N/A":      "N/A",
	} {
		if got := formatPrice(input); got != want {
			t.Errorf("formatPrice(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestRunRendersQuoteDirection(t *testing.T) {
	for name, test := range map[string]struct {
		quote Quote
		icon  string
		color string
	}{
		"up":   {Quote{"$100", "up"}, upIcon, defaultGreen},
		"down": {Quote{"$99.5", "down"}, downIcon, defaultRed},
	} {
		t.Run(name, func(t *testing.T) {
			bar := &recordingBar{}
			if err := Run(context.Background(), testConfig(), fakeQuoteFetcher{quote: test.quote}, bar); err != nil {
				t.Fatalf("Run returned an error: %v", err)
			}
			want := [][]string{{
				"--set", "stock", "icon=" + test.icon,
				"icon.color=" + test.color,
				"label=" + formatPrice(test.quote.LastSalePrice),
			}}
			if !reflect.DeepEqual(bar.calls, want) {
				t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
			}
		})
	}
}

func TestRunShowsUnavailableQuote(t *testing.T) {
	bar := &recordingBar{}
	err := Run(
		context.Background(),
		testConfig(),
		fakeQuoteFetcher{err: errors.New("unavailable")},
		bar,
	)
	if err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{
		"--set", "stock", "icon=" + unavailableIcon,
		"icon.color=" + defaultYellow, "label=NVDA",
	}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}
