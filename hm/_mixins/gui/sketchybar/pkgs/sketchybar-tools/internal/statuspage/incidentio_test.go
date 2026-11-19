package statuspage

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
)

func TestRunTracksOpenAIStatusGroups(t *testing.T) {
	const structure = `{"items":[
		{"group":{"name":"APIs","components":[{"component_id":"api-login","name":"Login"}]}},
		{"group":{"name":"ChatGPT","components":[{"component_id":"chatgpt-login","name":"Login"}]}},
		{"group":{"name":"Codex","components":[{"component_id":"codex-cli","name":"CLI"}]}},
		{"group":{"name":"Ads Platform","components":[{"component_id":"ads-api","name":"Ads API"}]}}
	]}`
	for affected, drawing := range map[string]string{
		"api-login":     "on",
		"chatgpt-login": "on",
		"codex-cli":     "on",
		"ads-api":       "off",
	} {
		t.Run(affected, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				body := map[string]any{
					"summary": map[string]any{
						"structure": json.RawMessage(structure),
						"affected_components": []map[string]string{{
							"component_id": affected,
							"status":       "partial_outage",
						}},
						"ongoing_incidents": []map[string]string{{"name": "Service degradation"}},
					},
				}
				if err := json.NewEncoder(writer).Encode(body); err != nil {
					t.Error(err)
				}
			}))
			t.Cleanup(server.Close)

			values := map[string]string{
				"NAME":                  "openai-status",
				"SKETCHYBAR_BIN":        "/sketchybar",
				"STATUSPAGE_COMPONENTS": `["APIs","ChatGPT","Codex"]`,
				"STATUSPAGE_FORMAT":     "incident-io",
				"STATUSPAGE_ICON":       "icon",
				"STATUSPAGE_URL":        server.URL,
			}
			config, err := ConfigFromEnvironment(func(name string) string { return values[name] })
			if err != nil {
				t.Fatal(err)
			}

			bar := &recordingBar{}
			if err := Run(t.Context(), config, NewHTTPSummaryFetcher(config), bar); err != nil {
				t.Fatal(err)
			}
			if len(bar.calls) != 1 || !slices.Contains(bar.calls[0], "drawing="+drawing) {
				t.Errorf("SketchyBar calls = %v, want drawing=%s", bar.calls, drawing)
			}
		})
	}
}
