package alertmanager

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/httpclient"
)

const maxResponseBytes = 10 << 20

type Alert struct {
	Labels      AlertLabels      `json:"labels"`
	Annotations AlertAnnotations `json:"annotations"`
}

type AlertLabels struct {
	Name     string `json:"alertname"`
	Instance string `json:"instance"`
	Severity string `json:"severity"`
}

type AlertAnnotations struct {
	Summary string `json:"summary"`
}

type HTTPAlertFetcher struct {
	config Config
}

func NewHTTPAlertFetcher(config Config) HTTPAlertFetcher {
	return HTTPAlertFetcher{config: config}
}

func (fetcher HTTPAlertFetcher) Fetch(ctx context.Context) ([]Alert, error) {
	client, err := httpclient.NewMTLS(httpclient.MTLSConfig{
		CACertificate:     fetcher.config.CACertificate,
		ClientCertificate: fetcher.config.ClientCertificate,
		ClientKey:         fetcher.config.ClientKey,
		Timeout:           10 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("configure Alertmanager client: %w", err)
	}
	endpoint, err := alertsURL(fetcher.config.URL)
	if err != nil {
		return nil, err
	}
	body, err := httpclient.Get(ctx, client, endpoint, maxResponseBytes)
	if err != nil {
		return nil, fmt.Errorf("fetch Alertmanager alerts: %w", err)
	}
	return decodeAlerts(body)
}

func alertsURL(rawURL string) (string, error) {
	endpoint, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("parse Alertmanager URL: %w", err)
	}
	query := endpoint.Query()
	query.Set("active", "true")
	query.Set("silenced", "false")
	query.Set("inhibited", "false")
	endpoint.RawQuery = query.Encode()
	return endpoint.String(), nil
}

func decodeAlerts(body []byte) ([]Alert, error) {
	var alerts []Alert
	if err := json.Unmarshal(body, &alerts); err != nil {
		return nil, fmt.Errorf("decode Alertmanager response: %w", err)
	}
	if alerts == nil {
		return nil, fmt.Errorf("decode Alertmanager response: expected an array")
	}
	return alerts, nil
}
