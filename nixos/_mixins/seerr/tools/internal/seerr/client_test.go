package seerr_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
)

func intPointer(value int) *int { return &value }

func TestRequestServiceID(t *testing.T) {
	tests := []struct {
		name    string
		request seerr.Request
		want    int
		ok      bool
	}{
		{"explicit", seerr.Request{ServerID: intPointer(0)}, 0, true},
		{
			"media",
			seerr.Request{Media: &seerr.Media{ServiceID: intPointer(3)}},
			3,
			true,
		},
		{
			"4k media",
			seerr.Request{
				Is4K:  true,
				Media: &seerr.Media{ServiceID4K: intPointer(4)},
			},
			4,
			true,
		},
		{"missing", seerr.Request{}, 0, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := test.request.ServiceID()
			if got != test.want || ok != test.ok {
				t.Fatalf("ServiceID() = (%d, %t), want (%d, %t)", got, ok, test.want, test.ok)
			}
		})
	}
}

func TestServiceURL(t *testing.T) {
	service := seerr.Service{
		Hostname: "2001:db8::1",
		Port:     8989,
	}
	if got := service.URL(); got != "http://[2001:db8::1]:8989" {
		t.Fatalf("URL() = %q", got)
	}
}

func TestClientUsesTypedServiceAndRequestEndpoints(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("X-Api-Key") != "secret" {
			http.Error(writer, "missing key", http.StatusUnauthorized)
			return
		}
		switch request.URL.RequestURI() {
		case "/api/v1/settings/radarr":
			fmt.Fprint(writer, `[{"id":0,"name":"radarr","hostname":"radarr","port":7878,"apiKey":"radarr-key"}]`)
		case "/api/v1/request?take=1&skip=0":
			fmt.Fprint(writer, `{"pageInfo":{"results":2},"results":[{"id":1,"status":2,"type":"movie"}]}`)
		case "/api/v1/request?take=1&skip=1":
			fmt.Fprint(writer, `{"pageInfo":{"results":2},"results":[{"id":2,"status":5,"type":"tv","seasons":[{"seasonNumber":3}]}]}`)
		default:
			http.Error(writer, request.URL.RequestURI(), http.StatusNotFound)
		}
	}))
	defer server.Close()

	client, err := seerr.NewClient(server.URL, "secret", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	services, err := client.Services(context.Background(), seerr.Radarr)
	if err != nil || len(services) != 1 || services[0].ID != 0 {
		t.Fatalf("Services() = %#v, %v", services, err)
	}
	requests, err := client.Requests(context.Background(), 1)
	if err != nil || len(requests) != 2 || requests[1].Seasons[0].Number != 3 {
		t.Fatalf("Requests() = %#v, %v", requests, err)
	}
}

func TestReadAPIKey(t *testing.T) {
	t.Setenv("SEERR_API_KEY", "")
	directory := t.TempDir()
	settingsPath := filepath.Join(directory, "settings.json")
	if err := os.WriteFile(settingsPath, []byte(`{"main":{"apiKey":"secret"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	key, err := seerr.ReadAPIKey(settingsPath)
	if err != nil || key != "secret" {
		t.Fatalf("ReadAPIKey() = %q, %v", key, err)
	}
	rawPath := filepath.Join(directory, "key")
	if err := os.WriteFile(rawPath, []byte("raw-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	key, err = seerr.ReadAPIKey(rawPath)
	if err != nil || key != "raw-secret" {
		t.Fatalf("ReadAPIKey(raw) = %q, %v", key, err)
	}
}
