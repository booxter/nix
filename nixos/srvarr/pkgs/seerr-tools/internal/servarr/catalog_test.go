package servarr_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
	"time"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/booxter/nix-config/seerr-tools/internal/servarr"
)

func serviceForServer(t *testing.T, server *httptest.Server) seerr.Service {
	t.Helper()
	parsed, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil {
		t.Fatal(err)
	}
	return seerr.Service{
		ID:       1,
		Name:     "test",
		Hostname: parsed.Hostname(),
		Port:     port,
		APIKey:   "secret",
	}
}

func TestCatalogUsesNativeClients(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("X-Api-Key") != "secret" {
			http.Error(writer, "missing key", http.StatusUnauthorized)
			return
		}
		switch request.URL.RequestURI() {
		case "/api/v3/movie":
			fmt.Fprint(writer, `[{"id":1,"title":"Movie","tmdbId":10}]`)
		case "/api/v3/series":
			fmt.Fprint(writer, `[{"id":2,"title":"Series","tvdbId":20}]`)
		case "/api/v3/episodefile?seriesId=2":
			fmt.Fprint(writer, `[{"id":3,"seriesId":2,"seasonNumber":1,"size":100}]`)
		default:
			http.Error(writer, request.URL.RequestURI(), http.StatusNotFound)
		}
	}))
	defer server.Close()

	service := serviceForServer(t, server)
	catalog := servarr.NewCatalog(time.Second)
	movies, err := catalog.Movies(context.Background(), service)
	if err != nil || len(movies) != 1 || movies[0].TmdbID != 10 {
		t.Fatalf("Movies() = %#v, %v", movies, err)
	}
	series, err := catalog.Series(context.Background(), service)
	if err != nil || len(series) != 1 || series[0].TvdbID != 20 {
		t.Fatalf("Series() = %#v, %v", series, err)
	}
	files, err := catalog.EpisodeFiles(context.Background(), service, 2)
	if err != nil || len(files) != 1 || files[0].Size != 100 {
		t.Fatalf("EpisodeFiles() = %#v, %v", files, err)
	}
}
