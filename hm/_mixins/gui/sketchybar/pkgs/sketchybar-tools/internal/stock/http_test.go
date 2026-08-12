package stock

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPQuoteFetcherUsesNasdaqRequestContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
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
		response.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(response).Encode(map[string]any{
			"data": map[string]any{
				"primaryData": map[string]string{
					"lastSalePrice":  "$512.5",
					"deltaIndicator": "up",
				},
			},
		}); err != nil {
			t.Errorf("encode response: %v", err)
		}
	}))
	defer server.Close()

	fetcher, err := NewHTTPQuoteFetcher(Config{
		APIURL: server.URL + "/api/quote",
		Symbol: "BRK.B",
	})
	if err != nil {
		t.Fatalf("NewHTTPQuoteFetcher returned an error: %v", err)
	}

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
