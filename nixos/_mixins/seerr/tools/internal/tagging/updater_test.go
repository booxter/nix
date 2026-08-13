package tagging

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/booxter/nix-config/seerr-tools/internal/servarr"
	"github.com/golusoris/goenvoy/arr/radarr"
	"github.com/golusoris/goenvoy/arr/sonarr"
	"github.com/golusoris/goenvoy/arr/v2"
)

type arrAPI struct {
	t           *testing.T
	tags        []arr.Tag
	movies      []radarr.Movie
	series      []sonarr.Series
	mutations   []string
	movieEdits  []radarr.MovieEditorResource
	seriesEdits []sonarr.SeriesEditorResource
}

func (api *arrAPI) serve(response http.ResponseWriter, request *http.Request) {
	api.t.Helper()
	if request.Header.Get("X-Api-Key") != "secret" {
		http.Error(response, "missing API key", http.StatusUnauthorized)
		return
	}
	path := request.URL.Path
	switch {
	case request.Method == http.MethodGet && path == "/api/v3/movie":
		api.writeJSON(response, api.movies)
	case request.Method == http.MethodGet && path == "/api/v3/series":
		api.writeJSON(response, api.series)
	case request.Method == http.MethodGet && path == "/api/v3/tag":
		api.writeJSON(response, api.tags)
	case request.Method == http.MethodPost && path == "/api/v3/tag":
		var tag arr.Tag
		api.decode(request, &tag)
		tag.ID = 10
		api.tags = append(api.tags, tag)
		api.mutations = append(api.mutations, request.Method+" "+path)
		api.writeJSON(response, tag)
	case request.Method == http.MethodPut && path == "/api/v3/movie/editor":
		var editor radarr.MovieEditorResource
		api.decode(request, &editor)
		api.movieEdits = append(api.movieEdits, editor)
		api.mutations = append(api.mutations, request.Method+" "+path)
		response.WriteHeader(http.StatusAccepted)
	case request.Method == http.MethodPut && path == "/api/v3/series/editor":
		var editor sonarr.SeriesEditorResource
		api.decode(request, &editor)
		api.seriesEdits = append(api.seriesEdits, editor)
		api.mutations = append(api.mutations, request.Method+" "+path)
		api.writeJSON(response, []sonarr.Series{})
	default:
		http.Error(response, request.Method+" "+path, http.StatusNotFound)
	}
}

func (api *arrAPI) decode(request *http.Request, target any) {
	api.t.Helper()
	if err := json.NewDecoder(request.Body).Decode(target); err != nil {
		api.t.Errorf("decode request: %v", err)
	}
}

func (api *arrAPI) writeJSON(response http.ResponseWriter, value any) {
	api.t.Helper()
	response.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(response).Encode(value); err != nil {
		api.t.Errorf("encode response: %v", err)
	}
}

func serviceForServer(t *testing.T, server *httptest.Server, id int, name string) seerr.Service {
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
		ID:          id,
		Name:        name,
		Hostname:    parsed.Hostname(),
		Port:        port,
		APIKey:      "secret",
		TagRequests: true,
	}
}

func intPointer(value int) *int { return &value }

func requests() []seerr.Request {
	return []seerr.Request{
		{
			ID:          1,
			Status:      seerr.RequestApproved,
			Type:        "movie",
			ServerID:    intPointer(0),
			RequestedBy: &seerr.User{ID: 7, DisplayName: "Éve  User!"},
			Media:       &seerr.Media{TmdbID: intPointer(101)},
		},
		{
			ID:          2,
			Status:      seerr.RequestCompleted,
			Type:        "tv",
			ServerID:    intPointer(0),
			RequestedBy: &seerr.User{ID: 8, DisplayName: "Sam"},
			Media:       &seerr.Media{TvdbID: intPointer(202)},
		},
		{
			ID:          3,
			Status:      3,
			Type:        "movie",
			ServerID:    intPointer(0),
			RequestedBy: &seerr.User{ID: 9, DisplayName: "Declined"},
			Media:       &seerr.Media{TmdbID: intPointer(303)},
		},
	}
}

func runScenario(t *testing.T, apply bool) (Stats, string, *arrAPI, *arrAPI) {
	t.Helper()
	radarrAPI := &arrAPI{
		t:      t,
		movies: []radarr.Movie{{ID: 11, Title: "Movie", TmdbID: 101}},
	}
	radarrServer := httptest.NewServer(http.HandlerFunc(radarrAPI.serve))
	defer radarrServer.Close()
	sonarrAPI := &arrAPI{
		t:      t,
		tags:   []arr.Tag{{ID: 20, Label: "8-Sam"}},
		series: []sonarr.Series{{ID: 22, Title: "Series", TvdbID: 202}},
	}
	sonarrServer := httptest.NewServer(http.HandlerFunc(sonarrAPI.serve))
	defer sonarrServer.Close()

	var output bytes.Buffer
	stats, err := Update(
		context.Background(),
		requests(),
		[]seerr.Service{serviceForServer(t, radarrServer, 0, "radarr")},
		[]seerr.Service{serviceForServer(t, sonarrServer, 0, "sonarr")},
		servarr.NewCatalog(0),
		Options{Apply: apply, BatchSize: 500},
		&output,
	)
	if err != nil {
		t.Fatal(err)
	}
	return stats, output.String(), radarrAPI, sonarrAPI
}

func TestDryRunIsReadOnly(t *testing.T) {
	stats, output, radarrAPI, sonarrAPI := runScenario(t, false)
	if len(radarrAPI.mutations) != 0 || len(sonarrAPI.mutations) != 0 {
		t.Fatalf("dry run mutations = %v, %v", radarrAPI.mutations, sonarrAPI.mutations)
	}
	want := Stats{
		Requests:           3,
		EligibleRequests:   2,
		UniqueAttributions: 2,
		TagsToCreate:       1,
		ItemsToUpdate:      2,
		SkippedRequests:    1,
	}
	if stats != want {
		t.Fatalf("stats = %#v, want %#v", stats, want)
	}
	if !strings.Contains(output, "WOULD CREATE tag 7-Eve-User") {
		t.Fatalf("output does not describe missing tag:\n%s", output)
	}
}

func TestApplyUsesNativeBulkTagClients(t *testing.T) {
	stats, _, radarrAPI, sonarrAPI := runScenario(t, true)
	if stats.ItemsToUpdate != 2 || stats.TagsToCreate != 1 {
		t.Fatalf("stats = %#v", stats)
	}
	if len(radarrAPI.tags) != 1 || radarrAPI.tags[0] != (arr.Tag{ID: 10, Label: "7-Eve-User"}) {
		t.Fatalf("Radarr tags = %#v", radarrAPI.tags)
	}
	if len(radarrAPI.movieEdits) != 1 {
		t.Fatalf("Radarr edits = %#v", radarrAPI.movieEdits)
	}
	movieEdit := radarrAPI.movieEdits[0]
	if len(movieEdit.MovieIDs) != 1 || movieEdit.MovieIDs[0] != 11 ||
		len(movieEdit.Tags) != 1 || movieEdit.Tags[0] != 10 || movieEdit.ApplyTags != "add" {
		t.Fatalf("Radarr edit = %#v", movieEdit)
	}
	if len(sonarrAPI.seriesEdits) != 1 {
		t.Fatalf("Sonarr edits = %#v", sonarrAPI.seriesEdits)
	}
	seriesEdit := sonarrAPI.seriesEdits[0]
	if len(seriesEdit.SeriesIDs) != 1 || seriesEdit.SeriesIDs[0] != 22 ||
		len(seriesEdit.Tags) != 1 || seriesEdit.Tags[0] != 20 || seriesEdit.ApplyTags != "add" {
		t.Fatalf("Sonarr edit = %#v", seriesEdit)
	}
}

func TestTagLabelsMatchSeerr(t *testing.T) {
	user := seerr.User{ID: 7, DisplayName: " Éve  User! "}
	if got := expectedTag(user); got != "7-Eve-User" {
		t.Fatalf("expectedTag() = %q", got)
	}
	tags := []arr.Tag{{ID: 1, Label: "12-Someone"}, {ID: 2, Label: "1 - Legacy"}}
	if tag, ok := findUserTag(tags, 1); !ok || tag.ID != 2 {
		t.Fatalf("findUserTag() = %#v, %t", tag, ok)
	}
}
