package alertmanager

import (
	"net/url"
	"reflect"
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

func TestDecodeAlertsRequiresAnArray(t *testing.T) {
	cases := map[string]struct {
		body    string
		alerts  []Alert
		wantErr bool
	}{
		"empty": {body: `[]`, alerts: []Alert{}},
		"alerts": {
			body: `[{"labels":{"alertname":"DiskFull","instance":"server","severity":"critical"},` +
				`"annotations":{"summary":"Disk is full"}}]`,
			alerts: []Alert{{
				Labels:      AlertLabels{Name: "DiskFull", Instance: "server", Severity: "critical"},
				Annotations: AlertAnnotations{Summary: "Disk is full"},
			}},
		},
		"object":  {body: `{"status":"ok"}`, wantErr: true},
		"null":    {body: `null`, wantErr: true},
		"invalid": {body: `{`, wantErr: true},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			alerts, err := decodeAlerts([]byte(test.body))
			if (err != nil) != test.wantErr {
				t.Fatalf("decodeAlerts error = %v, wantErr %v", err, test.wantErr)
			}
			if !reflect.DeepEqual(alerts, test.alerts) {
				t.Errorf("decodeAlerts = %#v, want %#v", alerts, test.alerts)
			}
		})
	}
}
