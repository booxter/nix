package alertmanager

import (
	"net/url"
	"testing"
)

func TestAlertsURLAddsRequiredFilters(t *testing.T) {
	endpoint, err := alertsURL("https://alertmanager.test/api/v2/alerts?receiver=desktop")
	if err != nil {
		t.Fatalf("alertsURL returned an error: %v", err)
	}
	parsed, err := url.Parse(endpoint)
	if err != nil {
		t.Fatalf("parse result: %v", err)
	}
	want := map[string]string{
		"active":    "true",
		"silenced":  "false",
		"inhibited": "false",
		"receiver":  "desktop",
	}
	for name, value := range want {
		if got := parsed.Query().Get(name); got != value {
			t.Errorf("query parameter %s = %q, want %q", name, got, value)
		}
	}
}

func TestDecodeAlertCountRequiresAnArray(t *testing.T) {
	cases := map[string]struct {
		body    string
		count   int
		wantErr bool
	}{
		"empty":   {body: `[]`, count: 0},
		"alerts":  {body: `[{"labels":{"alertname":"one"}},{"labels":{"alertname":"two"}}]`, count: 2},
		"object":  {body: `{"status":"ok"}`, wantErr: true},
		"null":    {body: `null`, wantErr: true},
		"invalid": {body: `{`, wantErr: true},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			count, err := decodeAlertCount([]byte(test.body))
			if (err != nil) != test.wantErr {
				t.Fatalf("decodeAlertCount error = %v, wantErr %v", err, test.wantErr)
			}
			if count != test.count {
				t.Errorf("decodeAlertCount = %d, want %d", count, test.count)
			}
		})
	}
}
