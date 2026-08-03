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

type HTTPAlertCounter struct {
	config Config
}

func NewHTTPAlertCounter(config Config) HTTPAlertCounter {
	return HTTPAlertCounter{config: config}
}

func (counter HTTPAlertCounter) Count(ctx context.Context) (int, error) {
	client, err := httpclient.NewMTLS(httpclient.MTLSConfig{
		CACertificate:     counter.config.CACertificate,
		ClientCertificate: counter.config.ClientCertificate,
		ClientKey:         counter.config.ClientKey,
		Timeout:           10 * time.Second,
	})
	if err != nil {
		return 0, fmt.Errorf("configure Alertmanager client: %w", err)
	}
	endpoint, err := alertsURL(counter.config.URL)
	if err != nil {
		return 0, err
	}
	body, err := httpclient.Get(ctx, client, endpoint, maxResponseBytes)
	if err != nil {
		return 0, fmt.Errorf("fetch Alertmanager alerts: %w", err)
	}
	return decodeAlertCount(body)
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

func decodeAlertCount(body []byte) (int, error) {
	var alerts []json.RawMessage
	if err := json.Unmarshal(body, &alerts); err != nil {
		return 0, fmt.Errorf("decode Alertmanager response: %w", err)
	}
	if alerts == nil {
		return 0, fmt.Errorf("decode Alertmanager response: expected an array")
	}
	return len(alerts), nil
}
