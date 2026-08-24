package alertmanager

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fakeFetcher struct {
	alerts []Alert
	err    error
}

func (fetcher fakeFetcher) Fetch(context.Context) ([]Alert, error) {
	return fetcher.alerts, fetcher.err
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

func joinedCalls(bar *recordingBar) string {
	rows := make([]string, 0, len(bar.calls))
	for _, call := range bar.calls {
		rows = append(rows, strings.Join(call, " "))
	}
	return strings.Join(rows, "\n")
}

func TestRunHidesItemAndPopupWithoutFiringAlerts(t *testing.T) {
	bar := &recordingBar{}
	if err := Run(context.Background(), testConfig(), fakeFetcher{}, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	calls := joinedCalls(bar)
	for _, expected := range []string{
		"--set alertmanager.alert.7 drawing=off",
		"--set alertmanager.more drawing=off",
		"--set alertmanager drawing=off popup.drawing=off",
	} {
		if !strings.Contains(calls, expected) {
			t.Errorf("missing call %q:\n%s", expected, calls)
		}
	}
}

func TestRunRendersAlertsAndTogglesPopupOnClick(t *testing.T) {
	config := testConfig()
	config.Sender = "mouse.clicked"
	bar := &recordingBar{}
	alerts := []Alert{
		{
			Labels:      AlertLabels{Name: "DiskFull", Instance: "server", Severity: "critical"},
			Annotations: AlertAnnotations{Summary: "  Disk   is full\n"},
		},
		{
			Labels: AlertLabels{Name: "BackupFailed", Instance: "backup", Severity: "warning"},
		},
	}
	if err := Run(context.Background(), config, fakeFetcher{alerts: alerts}, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	calls := joinedCalls(bar)
	for _, expected := range []string{
		"--set alertmanager.alert.0 drawing=on label=server · Disk is full label.color=" + defaultRed,
		"--set alertmanager.alert.1 drawing=on label=backup · BackupFailed label.color=" + defaultYellow,
		"--set alertmanager.alert.7 drawing=off",
		"--set alertmanager.more drawing=off",
		"--set alertmanager drawing=on icon=! icon.color=" + defaultRed +
			" label=2 label.color=" + defaultRed + " popup.drawing=toggle",
	} {
		if !strings.Contains(calls, expected) {
			t.Errorf("missing call %q:\n%s", expected, calls)
		}
	}
}

func TestRunShowsOverflowCount(t *testing.T) {
	alerts := make([]Alert, maxPopupAlerts+3)
	bar := &recordingBar{}
	if err := Run(context.Background(), testConfig(), fakeFetcher{alerts: alerts}, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	calls := joinedCalls(bar)
	if !strings.Contains(calls, "--set alertmanager.more drawing=on label=… 3 more") {
		t.Fatalf("overflow was not rendered:\n%s", calls)
	}
	if strings.Contains(calls, "alertmanager.alert.8") {
		t.Fatalf("an unconfigured popup row was updated:\n%s", calls)
	}
}

func TestRunShowsErrorStateWhenAlertmanagerIsUnavailable(t *testing.T) {
	bar := &recordingBar{}
	unavailable := errors.New("unavailable")
	err := Run(context.Background(), testConfig(), fakeFetcher{err: unavailable}, bar)
	if !errors.Is(err, unavailable) {
		t.Fatalf("Run error = %v, want unavailable", err)
	}
	calls := joinedCalls(bar)
	for _, expected := range []string{
		"--set alertmanager.alert.7 drawing=off",
		"--set alertmanager.more drawing=off",
		"--set alertmanager drawing=on popup.drawing=off icon=! icon.color=" + defaultYellow +
			" label=? label.color=" + defaultYellow,
	} {
		if !strings.Contains(calls, expected) {
			t.Errorf("missing call %q:\n%s", expected, calls)
		}
	}
}

func TestRunPropagatesSketchybarFailure(t *testing.T) {
	bar := &recordingBar{err: errors.New("bar failed")}
	if err := Run(context.Background(), testConfig(), fakeFetcher{}, bar); err == nil {
		t.Fatal("expected SketchyBar failure")
	}
}

func TestAlertLabelFallsBackToAvailableFields(t *testing.T) {
	cases := map[string]struct {
		alert Alert
		want  string
	}{
		"summary": {
			alert: Alert{Annotations: AlertAnnotations{Summary: "Alert summary"}},
			want:  "Alert summary",
		},
		"name": {
			alert: Alert{Labels: AlertLabels{Name: "AlertName"}},
			want:  "AlertName",
		},
		"instance": {
			alert: Alert{Labels: AlertLabels{Instance: "server"}},
			want:  "server",
		},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			if got := AlertLabel(test.alert); got != test.want {
				t.Errorf("AlertLabel = %q, want %q", got, test.want)
			}
		})
	}
}
