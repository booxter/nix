package httpclient

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

type MTLSConfig struct {
	CACertificate     string
	ClientCertificate string
	ClientKey         string
	Timeout           time.Duration
}

func NewMTLS(config MTLSConfig) (*http.Client, error) {
	rootPEM, err := os.ReadFile(config.CACertificate)
	if err != nil {
		return nil, fmt.Errorf("read CA certificate: %w", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(rootPEM) {
		return nil, fmt.Errorf("CA certificate contains no certificates")
	}
	certificate, err := tls.LoadX509KeyPair(config.ClientCertificate, config.ClientKey)
	if err != nil {
		return nil, fmt.Errorf("load client certificate: %w", err)
	}
	return &http.Client{
		Timeout: config.Timeout,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			RootCAs:      roots,
			Certificates: []tls.Certificate{certificate},
		}},
	}, nil
}

func Get(ctx context.Context, client *http.Client, url string, maxBytes int64) ([]byte, error) {
	return GetWithHeaders(ctx, client, url, maxBytes, nil)
}

func GetWithHeaders(
	ctx context.Context,
	client *http.Client,
	url string,
	maxBytes int64,
	headers http.Header,
) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	request.Header = headers.Clone()
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("send request: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %s", response.Status)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if int64(len(body)) > maxBytes {
		return nil, fmt.Errorf("response exceeds %d bytes", maxBytes)
	}
	return body, nil
}
