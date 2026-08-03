package jellyfin

import (
	"strings"
	"testing"
)

func TestAddressScopeUsesNativeIPClassification(t *testing.T) {
	cases := map[string]string{
		"192.168.1.20":      "LAN",
		"10.0.0.2:8096":     "LAN",
		"[fd00::2]:8096":    "LAN",
		"::ffff:8.8.8.8":    "WAN",
		"2001:4860:4860::8": "WAN",
		"not-an-address":    "unknown",
	}
	for address, expected := range cases {
		if actual := addressScope(address); actual != expected {
			t.Errorf("addressScope(%q) = %q, want %q", address, actual, expected)
		}
	}
}

func TestParseMetricsHandlesEscapedLabels(t *testing.T) {
	metrics := healthyMetrics + `jellyfin_now_playing_state{device="Browser",method="DirectPlay",title="A \"Quoted\" Film",type="Movie",user_id="one",username="One"} 1` + "\n"
	sessions, err := ParseMetrics(strings.NewReader(metrics))
	if err != nil {
		t.Fatalf("ParseMetrics returned an error: %v", err)
	}
	if len(sessions) != 1 || sessions[0].Title != `A "Quoted" Film` {
		t.Fatalf("escaped title was not parsed: %#v", sessions)
	}
}

func TestSessionAndBandwidthFormatting(t *testing.T) {
	progress := int64(61)
	bitrate := int64(5_000_000)
	session := Session{
		Scope:         "unknown",
		Username:      "Three",
		Device:        "Tablet",
		MediaType:     "Episode",
		Title:         "The Episode",
		SeriesTitle:   "A Series",
		SeriesSeason:  "2",
		SeriesEpisode: "5",
		Method:        "DirectStream",
		Progress:      &progress,
		Bitrate:       &bitrate,
	}
	if actual, expected := SessionLabel(session), "unknown · Three · Tablet · A Series S2E5 — The Episode — paused at 61% · direct stream · 5 Mbit"; actual != expected {
		t.Fatalf("SessionLabel() = %q, want %q", actual, expected)
	}
	if actual, expected := formatRemaining(3660), "1h 01m left"; actual != expected {
		t.Fatalf("formatRemaining() = %q, want %q", actual, expected)
	}
	if actual, expected := formatBitrate(10_500_000), "10.5 Mbit"; actual != expected {
		t.Fatalf("formatBitrate() = %q, want %q", actual, expected)
	}
}
