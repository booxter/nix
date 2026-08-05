package seerr

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/golusoris/goenvoy/arr/v2"
)

const (
	RequestApproved  = 2
	RequestCompleted = 5
)

type ServiceKind string

const (
	Radarr ServiceKind = "radarr"
	Sonarr ServiceKind = "sonarr"
)

type User struct {
	ID          int    `json:"id"`
	DisplayName string `json:"displayName"`
}

type Season struct {
	Number int `json:"seasonNumber"`
}

type Media struct {
	TmdbID      *int `json:"tmdbId"`
	TvdbID      *int `json:"tvdbId"`
	ServiceID   *int `json:"serviceId"`
	ServiceID4K *int `json:"serviceId4k"`
}

type Request struct {
	ID          int      `json:"id"`
	Status      int      `json:"status"`
	Type        string   `json:"type"`
	Is4K        bool     `json:"is4k"`
	ServerID    *int     `json:"serverId"`
	RequestedBy *User    `json:"requestedBy"`
	Media       *Media   `json:"media"`
	Seasons     []Season `json:"seasons"`
}

func (request Request) ServiceID() (int, bool) {
	if request.ServerID != nil {
		return *request.ServerID, true
	}
	if request.Media == nil {
		return 0, false
	}
	serviceID := request.Media.ServiceID
	if request.Is4K {
		serviceID = request.Media.ServiceID4K
	}
	if serviceID == nil {
		return 0, false
	}
	return *serviceID, true
}

type Service struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Hostname    string `json:"hostname"`
	Port        int    `json:"port"`
	APIKey      string `json:"apiKey"`
	UseSSL      bool   `json:"useSsl"`
	TagRequests bool   `json:"tagRequests"`
}

func (service Service) URL() string {
	scheme := "http"
	if service.UseSSL {
		scheme = "https"
	}
	return (&url.URL{
		Scheme: scheme,
		Host:   net.JoinHostPort(service.Hostname, fmt.Sprint(service.Port)),
	}).String()
}

type PageInfo struct {
	Results int `json:"results"`
}

type requestPage struct {
	PageInfo PageInfo  `json:"pageInfo"`
	Results  []Request `json:"results"`
}

type Client struct {
	base *arr.BaseClient
}

func NewClient(baseURL, apiKey string, timeout time.Duration) (*Client, error) {
	base, err := arr.NewBaseClient(baseURL, apiKey, arr.WithTimeout(timeout))
	if err != nil {
		return nil, err
	}
	return &Client{base: base}, nil
}

// The goenvoy Seerr module follows Seerr's incomplete OpenAPI response model,
// which omits request type, seasons, media service IDs, and service settings.
// Use its shared transport here until those omissions are fixed upstream.
func (client *Client) Services(ctx context.Context, kind ServiceKind) ([]Service, error) {
	var services []Service
	if err := client.base.Get(ctx, "/api/v1/settings/"+string(kind), &services); err != nil {
		return nil, err
	}
	return services, nil
}

func (client *Client) Requests(ctx context.Context, pageSize int) ([]Request, error) {
	requests := make([]Request, 0)
	seen := make(map[int]bool)
	for skip := 0; ; {
		var page requestPage
		path := fmt.Sprintf("/api/v1/request?take=%d&skip=%d", pageSize, skip)
		if err := client.base.Get(ctx, path, &page); err != nil {
			return nil, err
		}
		if len(page.Results) == 0 {
			return requests, nil
		}
		added := 0
		for _, request := range page.Results {
			if !seen[request.ID] {
				seen[request.ID] = true
				requests = append(requests, request)
				added++
			}
		}
		if added == 0 {
			return nil, fmt.Errorf("Seerr request pagination repeated a page")
		}
		skip += len(page.Results)
		if len(page.Results) < pageSize || skip >= page.PageInfo.Results {
			return requests, nil
		}
	}
}

func ReadAPIKey(path string) (string, error) {
	if key := strings.TrimSpace(os.Getenv("SEERR_API_KEY")); key != "" {
		return key, nil
	}
	payload, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf(
			"read Seerr API key from %s: %w; set SEERR_API_KEY or use --api-key-file",
			path,
			err,
		)
	}
	text := strings.TrimSpace(string(payload))
	if text == "" {
		return "", fmt.Errorf("Seerr API key file is empty: %s", path)
	}
	var settings struct {
		Main struct {
			APIKey string `json:"apiKey"`
		} `json:"main"`
	}
	if err := json.Unmarshal(payload, &settings); err != nil {
		return text, nil
	}
	if key := strings.TrimSpace(settings.Main.APIKey); key != "" {
		return key, nil
	}
	return "", fmt.Errorf("no non-empty main.apiKey found in %s", path)
}
