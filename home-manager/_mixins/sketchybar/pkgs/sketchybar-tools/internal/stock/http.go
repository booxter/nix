package stock

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/booxter/nix-config/sketchybar-tools/internal/httpclient"
)

const maxResponseBytes = 1 << 20

type Quote struct {
	LastSalePrice string
	Direction     string
}

type HTTPQuoteFetcher struct {
	client   *http.Client
	endpoint string
}

func NewHTTPQuoteFetcher(config Config) (HTTPQuoteFetcher, error) {
	endpoint, err := url.Parse(config.APIURL)
	if err != nil {
		return HTTPQuoteFetcher{}, fmt.Errorf("parse stock API URL: %w", err)
	}
	endpoint = endpoint.JoinPath(config.Symbol, "info")
	query := endpoint.Query()
	query.Set("assetclass", "stocks")
	endpoint.RawQuery = query.Encode()
	return HTTPQuoteFetcher{
		client:   &http.Client{Timeout: 10 * time.Second},
		endpoint: endpoint.String(),
	}, nil
}

func (fetcher HTTPQuoteFetcher) Fetch(ctx context.Context) (Quote, error) {
	body, err := httpclient.GetWithHeaders(
		ctx,
		fetcher.client,
		fetcher.endpoint,
		maxResponseBytes,
		http.Header{
			"Accept":     {"application/json"},
			"User-Agent": {"Mozilla/5.0"},
		},
	)
	if err != nil {
		return Quote{}, fmt.Errorf("fetch stock quote: %w", err)
	}
	return decodeQuote(body)
}

func decodeQuote(body []byte) (Quote, error) {
	var response struct {
		Data *struct {
			PrimaryData *struct {
				LastSalePrice *string `json:"lastSalePrice"`
				Direction     string  `json:"deltaIndicator"`
			} `json:"primaryData"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return Quote{}, fmt.Errorf("decode stock quote: %w", err)
	}
	if response.Data == nil || response.Data.PrimaryData == nil ||
		response.Data.PrimaryData.LastSalePrice == nil ||
		strings.TrimSpace(*response.Data.PrimaryData.LastSalePrice) == "" {
		return Quote{}, fmt.Errorf("decode stock quote: missing last sale price")
	}
	return Quote{
		LastSalePrice: *response.Data.PrimaryData.LastSalePrice,
		Direction:     response.Data.PrimaryData.Direction,
	}, nil
}
