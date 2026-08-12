package jellyfin

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fakeFetcher struct {
	metrics string
	err     error
}

func (fetcher fakeFetcher) Fetch(context.Context) ([]byte, error) {
	return []byte(fetcher.metrics), fetcher.err
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
		Name:                 "jellyfin",
		MetricsURL:           "https://jellyfin.test/metrics",
		CACertificate:        "/ca",
		ClientCertificate:    "/cert",
		ClientKey:            "/key",
		Purple:               defaultPurple,
		Yellow:               defaultYellow,
		SketchybarExecutable: "/sketchybar",
	}
}

func joinedCalls(bar *recordingBar) string {
	rows := make([]string, 0, len(bar.calls))
	for _, call := range bar.calls {
		rows = append(rows, strings.Join(call, " "))
	}
	return strings.Join(rows, "\n")
}

func TestRunHidesItemWithoutSessions(t *testing.T) {
	bar := &recordingBar{}
	err := Run(context.Background(), testConfig(), fakeFetcher{metrics: healthyMetrics}, bar)
	if err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	calls := joinedCalls(bar)
	if !strings.Contains(calls, "--set jellyfin drawing=off popup.drawing=off") {
		t.Fatalf("parent item was not hidden:\n%s", calls)
	}
	if !strings.Contains(calls, "--set jellyfin.session.7 drawing=off") {
		t.Fatalf("popup rows were not hidden:\n%s", calls)
	}
}

func TestRunRendersSessionsBandwidthAndClickToggle(t *testing.T) {
	config := testConfig()
	config.Sender = "mouse.clicked"
	bar := &recordingBar{}
	err := Run(context.Background(), config, fakeFetcher{metrics: activeMetrics}, bar)
	if err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	calls := joinedCalls(bar)
	for _, expected := range []string{
		"--set jellyfin.bandwidth drawing=on label=WAN 10 Mbit · LAN 30 Mbit",
		"label=LAN · One · Living Room · A Film — 34m left · direct · 30 Mbit",
		"label=WAN · Two · Phone · A Song — playing · transcode · 10 Mbit",
		"label=unknown · Three · Tablet · A Series S2E5 — The Episode — paused at 61% · direct stream · 5 Mbit",
		"--set jellyfin drawing=on icon=󰼁 icon.color=0xffd3869b label=3 label.color=0xffd3869b popup.drawing=toggle",
	} {
		if !strings.Contains(calls, expected) {
			t.Errorf("missing call fragment %q:\n%s", expected, calls)
		}
	}
	if strings.Contains(calls, "ip_address=") {
		t.Fatalf("raw metric labels leaked into SketchyBar output:\n%s", calls)
	}
}

func TestRunMarksIncompleteBandwidth(t *testing.T) {
	bar := &recordingBar{}
	err := Run(context.Background(), testConfig(), fakeFetcher{metrics: incompleteMetrics}, bar)
	if err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	if calls := joinedCalls(bar); !strings.Contains(
		calls,
		"--set jellyfin.bandwidth drawing=on label=WAN ≥10.5 Mbit · LAN 0 Mbit",
	) {
		t.Fatalf("incomplete bandwidth was not marked:\n%s", calls)
	}
}

func TestRunShowsErrorStateForFetcherAndMetricFailures(t *testing.T) {
	cases := map[string]fakeFetcher{
		"fetch": {err: errors.New("unavailable")},
		"jellyfin down": {metrics: strings.Replace(
			healthyMetrics,
			"jellyfin_up 1",
			"jellyfin_up 0",
			1,
		)},
		"playing collector": {metrics: strings.Replace(
			healthyMetrics,
			`collector="playing"} 1`,
			`collector="playing"} 0`,
			1,
		)},
		"users collector": {metrics: strings.Replace(
			healthyMetrics,
			`collector="users"} 1`,
			`collector="users"} 0`,
			1,
		)},
		"invalid sample": {metrics: healthyMetrics + `jellyfin_now_playing_state{device="TV",title="Broken",type="Movie",user_id="one",username="One"} invalid` + "\n"},
	}
	for name, fetcher := range cases {
		t.Run(name, func(t *testing.T) {
			bar := &recordingBar{}
			if err := Run(context.Background(), testConfig(), fetcher, bar); err != nil {
				t.Fatalf("Run returned an error: %v", err)
			}
			calls := joinedCalls(bar)
			if !strings.Contains(
				calls,
				"--set jellyfin drawing=on popup.drawing=off icon=! icon.color=0xfffabd2f label=? label.color=0xfffabd2f",
			) {
				t.Fatalf("error state was not shown:\n%s", calls)
			}
		})
	}
}

func TestRunPropagatesSketchybarFailure(t *testing.T) {
	bar := &recordingBar{err: errors.New("bar failed")}
	if err := Run(context.Background(), testConfig(), fakeFetcher{metrics: healthyMetrics}, bar); err == nil {
		t.Fatal("expected SketchyBar failure")
	}
}

const healthyMetrics = `jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 1
`

const activeMetrics = healthyMetrics + `jellyfin_user_active{client="Jellyfin Web",device="Living Room",ip_address="192.168.1.20",user_id="one",username="One"} 1
jellyfin_user_active{client="Jellyfin Mobile",device="Phone",ip_address="8.8.8.8",user_id="two",username="Two"} 1
jellyfin_now_playing_state{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 1
jellyfin_now_playing_bitrate_bits_per_second{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 30000000
jellyfin_now_playing_remaining{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 2040
jellyfin_now_playing_progress{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 42
jellyfin_now_playing_state{device="Phone",method="Transcode",title="A Song",type="Audio",user_id="two",username="Two"} 1
jellyfin_now_playing_bitrate_bits_per_second{device="Phone",method="Transcode",title="A Song",type="Audio",user_id="two",username="Two"} 10000000
jellyfin_now_playing_state{device="Tablet",method="DirectStream",series_episode="5",series_season="2",series_title="A Series",title="The Episode",type="Episode",user_id="three",username="Three"} 0
jellyfin_now_playing_bitrate_bits_per_second{device="Tablet",method="DirectStream",series_episode="5",series_season="2",series_title="A Series",title="The Episode",type="Episode",user_id="three",username="Three"} 5000000
jellyfin_now_playing_progress{device="Tablet",method="DirectStream",series_episode="5",series_season="2",series_title="A Series",title="The Episode",type="Episode",user_id="three",username="Three"} 61
jellyfin_now_playing_state{device="Browser",title="Photo",type="Photo",user_id="four",username="Four"} 1
`

const incompleteMetrics = healthyMetrics + `jellyfin_user_active{client="Jellyfin Web",device="TV",ip_address="8.8.8.8",user_id="one",username="One"} 1
jellyfin_user_active{client="Jellyfin Mobile",device="Phone",ip_address="1.1.1.1",user_id="two",username="Two"} 1
jellyfin_now_playing_state{device="TV",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 1
jellyfin_now_playing_bitrate_bits_per_second{device="TV",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 10500000
jellyfin_now_playing_state{device="Phone",method="Transcode",title="A Song",type="Audio",user_id="two",username="Two"} 1
`
