package radarr

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestReadMovie(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		assertMovieRequest(t, request, 42)
		data, err := os.ReadFile(filepath.Join("testdata", "movie.json"))
		if err != nil {
			t.Error(err)
			http.Error(writer, "fixture unavailable", http.StatusInternalServerError)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write(data)
	}))
	defer server.Close()
	client, err := New(server.URL, "test-api-key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	movie, err := client.ReadMovie(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	if movie.ID != 42 || movie.TMDBID != 123456 || movie.Title != "Example Movie" ||
		movie.Year != 2026 || movie.IMDbID == nil || *movie.IMDbID != "tt1234567" ||
		movie.OriginalTitle == nil || *movie.OriginalTitle != "Le film original" ||
		movie.RuntimeMinutes == nil || *movie.RuntimeMinutes != 123 {
		t.Fatalf("movie = %#v", movie)
	}
	wantTitles := []string{"Le film", "The Motion Picture"}
	if !reflect.DeepEqual(movie.AlternateTitles, wantTitles) {
		t.Fatalf("alternate titles = %v, want %v", movie.AlternateTitles, wantTitles)
	}
}

func TestReadMovieNormalizesMissingOptionalFields(t *testing.T) {
	t.Parallel()

	response := validMovieResponse()
	server := movieServer(t, response)
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	movie, err := client.ReadMovie(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	if movie.IMDbID != nil || movie.OriginalTitle != nil || movie.RuntimeMinutes != nil {
		t.Fatalf("optional fields = IMDbID %v, original title %v, runtime %v", movie.IMDbID, movie.OriginalTitle, movie.RuntimeMinutes)
	}
	if movie.AlternateTitles == nil || len(movie.AlternateTitles) != 0 {
		t.Fatalf("alternate titles = %#v", movie.AlternateTitles)
	}
}

func TestReadMovieRejectsInvalidID(t *testing.T) {
	t.Parallel()

	client, err := New("http://radarr.example", "key", http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.ReadMovie(context.Background(), 0); err == nil {
		t.Fatal("invalid movie ID was accepted")
	}
}

func TestReadMovieRejectsInvalidResponse(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*testMovieResponse)
		want   string
	}{
		{
			name: "mismatched ID",
			mutate: func(movie *testMovieResponse) {
				movie.ID = 43
			},
			want: "returned movie ID 43",
		},
		{
			name: "missing TMDB ID",
			mutate: func(movie *testMovieResponse) {
				movie.TMDBID = 0
			},
			want: "TMDB ID must be positive",
		},
		{
			name: "blank title",
			mutate: func(movie *testMovieResponse) {
				movie.Title = " "
			},
			want: "title must not be blank",
		},
		{
			name: "invalid year",
			mutate: func(movie *testMovieResponse) {
				movie.Year = 0
			},
			want: "year 0 is out of range",
		},
		{
			name: "invalid IMDb ID",
			mutate: func(movie *testMovieResponse) {
				movie.IMDbID = "not-an-imdb-id"
			},
			want: "IMDb ID is invalid",
		},
		{
			name: "invalid runtime",
			mutate: func(movie *testMovieResponse) {
				movie.Runtime = maximumMovieRuntime + 1
			},
			want: "runtime 10081 minutes is out of range",
		},
		{
			name: "null alternate title",
			mutate: func(movie *testMovieResponse) {
				movie.AlternateTitles = []*testAlternativeTitle{nil}
			},
			want: "alternate title 0 is null",
		},
		{
			name: "duplicate alternate title",
			mutate: func(movie *testMovieResponse) {
				movie.AlternateTitles = []*testAlternativeTitle{{Title: "Same"}, {Title: "Same"}}
			},
			want: "duplicate alternate title",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			response := validMovieResponse()
			test.mutate(&response)
			server := movieServer(t, response)
			defer server.Close()
			client, err := New(server.URL, "key", server.Client())
			if err != nil {
				t.Fatal(err)
			}

			_, err = client.ReadMovie(context.Background(), 42)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestReadMovieSanitizesHTTPError(t *testing.T) {
	t.Parallel()

	const responseSecret = "do-not-expose-this-response"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		assertMovieRequest(t, request, 42)
		http.Error(writer, responseSecret, http.StatusNotFound)
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.ReadMovie(context.Background(), 42)
	if err == nil || strings.Contains(err.Error(), responseSecret) {
		t.Fatalf("error = %v", err)
	}
	var httpError *HTTPError
	if !errors.As(err, &httpError) || httpError.StatusCode != http.StatusNotFound {
		t.Fatalf("HTTP error = %#v", httpError)
	}
}

func TestReadMovieRejectsMalformedResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"id":`))
	}))
	defer server.Close()
	client, err := New(server.URL, "key", server.Client())
	if err != nil {
		t.Fatal(err)
	}

	if _, err := client.ReadMovie(context.Background(), 42); err == nil {
		t.Fatal("malformed response was accepted")
	}
}

type testMovieResponse struct {
	ID              int64                   `json:"id"`
	TMDBID          int64                   `json:"tmdbId"`
	IMDbID          string                  `json:"imdbId"`
	Title           string                  `json:"title"`
	OriginalTitle   string                  `json:"originalTitle"`
	AlternateTitles []*testAlternativeTitle `json:"alternateTitles"`
	Year            int                     `json:"year"`
	Runtime         int                     `json:"runtime"`
}

type testAlternativeTitle struct {
	Title string `json:"title"`
}

func validMovieResponse() testMovieResponse {
	return testMovieResponse{
		ID:              42,
		TMDBID:          123456,
		Title:           "Example Movie",
		AlternateTitles: []*testAlternativeTitle{},
		Year:            2026,
	}
}

func movieServer(t *testing.T, response any) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		assertMovieRequest(t, request, 42)
		writeJSON(t, writer, response)
	}))
}

func assertMovieRequest(t *testing.T, request *http.Request, movieID int64) {
	t.Helper()
	wantPath := fmt.Sprintf("/api/v3/movie/%d", movieID)
	if request.Method != http.MethodGet || request.URL.Path != wantPath {
		t.Errorf("request = %s %s, want GET %s", request.Method, request.URL.Path, wantPath)
	}
	if request.URL.RawQuery != "" {
		t.Errorf("query = %q", request.URL.RawQuery)
	}
	if key := request.Header.Get("X-Api-Key"); key == "" {
		t.Error("API key header is missing")
	}
}
