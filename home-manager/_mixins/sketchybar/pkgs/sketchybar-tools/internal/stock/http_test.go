package stock

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func TestHTTPQuoteFetcherUsesNasdaqRequestContract(t *testing.T) {
	fetcher, err := NewHTTPQuoteFetcher(Config{
		APIURL: "https://stock.test/api/quote",
		Symbol: "BRK.B",
	})
	if err != nil {
		t.Fatalf("NewHTTPQuoteFetcher returned an error: %v", err)
	}
	fetcher.client = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/api/quote/BRK.B/info" {
			t.Errorf("request path = %q, want /api/quote/BRK.B/info", request.URL.Path)
		}
		if got := request.URL.Query().Get("assetclass"); got != "stocks" {
			t.Errorf("assetclass = %q, want stocks", got)
		}
		if got := request.Header.Get("Accept"); got != "application/json" {
			t.Errorf("Accept = %q, want application/json", got)
		}
		if got := request.Header.Get("User-Agent"); got != "Mozilla/5.0" {
			t.Errorf("User-Agent = %q, want Mozilla/5.0", got)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body: io.NopCloser(strings.NewReader(
				`{"data":{"primaryData":{"lastSalePrice":"$512.5","deltaIndicator":"up"}}}`,
			)),
		}, nil
	})}

	quote, err := fetcher.Fetch(context.Background())
	if err != nil {
		t.Fatalf("Fetch returned an error: %v", err)
	}
	if quote.LastSalePrice != "$512.5" || quote.Direction != "up" {
		t.Errorf("unexpected quote: %#v", quote)
	}
}

func TestDecodeQuoteRejectsInvalidResponses(t *testing.T) {
	for name, body := range map[string]string{
		"malformed":     `{`,
		"missing data":  `{}`,
		"missing price": `{"data":{"primaryData":{"deltaIndicator":"up"}}}`,
		"empty price":   `{"data":{"primaryData":{"lastSalePrice":" "}}}`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := decodeQuote([]byte(body))
			if err == nil || !strings.Contains(err.Error(), "stock quote") {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}
