package githubstatus

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/httpclient"
)

const maxResponseBytes = 1 << 20

type Summary struct {
	Indicator  string
	Components []Component
	Incidents  int
}

type Component struct {
	Status any `json:"status"`
}

func (summary Summary) HasIssues() bool {
	if summary.Indicator != "none" || summary.Incidents > 0 {
		return true
	}
	for _, component := range summary.Components {
		status, ok := component.Status.(string)
		if !ok || status != "operational" {
			return true
		}
	}
	return false
}

type HTTPSummaryFetcher struct {
	config Config
}

func NewHTTPSummaryFetcher(config Config) HTTPSummaryFetcher {
	return HTTPSummaryFetcher{config: config}
}

func (fetcher HTTPSummaryFetcher) Fetch(ctx context.Context) (Summary, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	body, err := httpclient.Get(ctx, client, fetcher.config.URL, maxResponseBytes)
	if err != nil {
		return Summary{}, fmt.Errorf("fetch GitHub Status summary: %w", err)
	}
	return decodeSummary(body)
}

func decodeSummary(body []byte) (Summary, error) {
	var response struct {
		Status struct {
			Indicator *string `json:"indicator"`
		} `json:"status"`
		Components *[]Component       `json:"components"`
		Incidents  *[]json.RawMessage `json:"incidents"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return Summary{}, fmt.Errorf("decode GitHub Status response: %w", err)
	}
	if response.Status.Indicator == nil || response.Components == nil || response.Incidents == nil {
		return Summary{}, fmt.Errorf("decode GitHub Status response: unexpected structure")
	}
	return Summary{
		Indicator:  *response.Status.Indicator,
		Components: *response.Components,
		Incidents:  len(*response.Incidents),
	}, nil
}
