package jellyfin

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

const maxMetricsBytes = 10 << 20

type HTTPMetricsFetcher struct {
	config Config
}

func NewHTTPMetricsFetcher(config Config) HTTPMetricsFetcher {
	return HTTPMetricsFetcher{config: config}
}

func (fetcher HTTPMetricsFetcher) Fetch(ctx context.Context) ([]byte, error) {
	rootPEM, err := os.ReadFile(fetcher.config.CACertificate)
	if err != nil {
		return nil, fmt.Errorf("read Jellyfin CA certificate: %w", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(rootPEM) {
		return nil, fmt.Errorf("Jellyfin CA certificate contains no certificates")
	}
	certificate, err := tls.LoadX509KeyPair(
		fetcher.config.ClientCertificate,
		fetcher.config.ClientKey,
	)
	if err != nil {
		return nil, fmt.Errorf("load Jellyfin client certificate: %w", err)
	}

	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			RootCAs:      roots,
			Certificates: []tls.Certificate{certificate},
		}},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, fetcher.config.MetricsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create Jellyfin metrics request: %w", err)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("fetch Jellyfin metrics: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("fetch Jellyfin metrics: HTTP %s", response.Status)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxMetricsBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read Jellyfin metrics: %w", err)
	}
	if len(body) > maxMetricsBytes {
		return nil, fmt.Errorf("Jellyfin metrics response exceeds %d bytes", maxMetricsBytes)
	}
	return body, nil
}
