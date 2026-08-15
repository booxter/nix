package githubstatus

import "testing"

func TestSummaryHasIssues(t *testing.T) {
	cases := map[string]struct {
		body      string
		hasIssues bool
	}{
		"operational": {
			body: `{"status":{"indicator":"none"},"components":[{"status":"operational"}],"incidents":[]}`,
		},
		"aggregate": {
			body:      `{"status":{"indicator":"minor"},"components":[{"status":"operational"}],"incidents":[]}`,
			hasIssues: true,
		},
		"component": {
			body:      `{"status":{"indicator":"none"},"components":[{"status":"degraded_performance"}],"incidents":[]}`,
			hasIssues: true,
		},
		"incident": {
			body:      `{"status":{"indicator":"none"},"components":[{"status":"operational"}],"incidents":[{"status":"investigating"}]}`,
			hasIssues: true,
		},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			summary, err := decodeSummary([]byte(test.body))
			if err != nil {
				t.Fatalf("decodeSummary returned an error: %v", err)
			}
			if got := summary.HasIssues(); got != test.hasIssues {
				t.Errorf("HasIssues = %v, want %v", got, test.hasIssues)
			}
		})
	}
}

func TestDecodeSummaryRejectsInvalidResponses(t *testing.T) {
	for name, body := range map[string]string{
		"missing fields": `{"status":"ok"}`,
		"null fields":    `{"status":{"indicator":null},"components":null,"incidents":null}`,
		"malformed":      `{`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeSummary([]byte(body)); err == nil {
				t.Fatal("expected invalid response to fail")
			}
		})
	}
}
