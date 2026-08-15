package jellyfin

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/httpclient"
)

const maxMetricsBytes = 10 << 20

type HTTPMetricsFetcher struct {
	config Config
}

func NewHTTPMetricsFetcher(config Config) HTTPMetricsFetcher {
	return HTTPMetricsFetcher{config: config}
}

func (fetcher HTTPMetricsFetcher) Fetch(ctx context.Context) ([]byte, error) {
	client, err := httpclient.NewMTLS(httpclient.MTLSConfig{
		CACertificate:     fetcher.config.CACertificate,
		ClientCertificate: fetcher.config.ClientCertificate,
		ClientKey:         fetcher.config.ClientKey,
		Timeout:           10 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("configure Jellyfin metrics client: %w", err)
	}
	body, err := httpclient.Get(ctx, client, fetcher.config.MetricsURL, maxMetricsBytes)
	if err != nil {
		return nil, fmt.Errorf("fetch Jellyfin metrics: %w", err)
	}
	return body, nil
}
