package storage_test

import (
	"bytes"
	"context"
	"testing"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/booxter/nix-config/seerr-tools/internal/storage"
	"github.com/golusoris/goenvoy/arr/radarr"
	"github.com/golusoris/goenvoy/arr/sonarr"
)

func pointer(value int) *int { return &value }

type catalog struct{}

func (catalog) Movies(context.Context, seerr.Service) ([]radarr.Movie, error) {
	return []radarr.Movie{
		{ID: 11, TmdbID: 101, SizeOnDisk: 100, MovieFile: &radarr.MovieFile{ID: 111}},
		{ID: 12, TmdbID: 102, SizeOnDisk: 300, MovieFile: &radarr.MovieFile{ID: 112}},
	}, nil
}

func (catalog) Series(context.Context, seerr.Service) ([]sonarr.Series, error) {
	return []sonarr.Series{{ID: 21, TvdbID: 201}}, nil
}

func (catalog) EpisodeFiles(_ context.Context, _ seerr.Service, seriesID int) ([]sonarr.EpisodeFile, error) {
	if seriesID != 21 {
		panic("unexpected series")
	}
	return []sonarr.EpisodeFile{{ID: 211, SeasonNumber: 1, Size: 200}}, nil
}

func movieRequest(id, tmdbID int, user *seerr.User, status int) seerr.Request {
	return seerr.Request{
		ID:          id,
		Status:      status,
		Type:        "movie",
		ServerID:    pointer(0),
		RequestedBy: user,
		Media:       &seerr.Media{TmdbID: pointer(tmdbID)},
	}
}

func TestBuildAttributesSharedAndExclusiveStorage(t *testing.T) {
	userOne := &seerr.User{ID: 1, DisplayName: "One"}
	userTwo := &seerr.User{ID: 2, DisplayName: "Two"}
	requests := []seerr.Request{
		movieRequest(1, 101, userOne, seerr.RequestApproved),
		movieRequest(2, 101, userTwo, seerr.RequestApproved),
		movieRequest(3, 102, userOne, seerr.RequestApproved),
		movieRequest(4, 102, userOne, seerr.RequestApproved),
		{
			ID:          5,
			Status:      seerr.RequestCompleted,
			Type:        "tv",
			ServerID:    pointer(0),
			RequestedBy: userTwo,
			Media:       &seerr.Media{TvdbID: pointer(201)},
			Seasons:     []seerr.Season{{Number: 1}},
		},
		movieRequest(6, 999, userTwo, 3),
	}
	service := seerr.Service{ID: 0, Name: "main"}
	report, err := storage.Build(
		context.Background(),
		requests,
		[]seerr.Service{service},
		[]seerr.Service{service},
		catalog{},
	)
	if err != nil {
		t.Fatal(err)
	}
	rows := make(map[int]storage.UserRow)
	for _, row := range report.Users {
		rows[row.UserID] = row
	}
	if rows[1].LogicalBytes != 400 || rows[1].AllocatedBytes != 350 || rows[1].ExclusiveBytes != 300 {
		t.Fatalf("user one = %#v", rows[1])
	}
	if rows[1].Movies != 2 || rows[1].AllocatedPercent < 58.333 || rows[1].AllocatedPercent > 58.334 {
		t.Fatalf("user one = %#v", rows[1])
	}
	if rows[2].LogicalBytes != 300 || rows[2].MovieBytes != 100 || rows[2].TVBytes != 200 {
		t.Fatalf("user two = %#v", rows[2])
	}
	if rows[2].AllocatedBytes != 250 || rows[2].ExclusiveBytes != 200 || rows[2].Series != 1 || rows[2].Seasons != 1 {
		t.Fatalf("user two = %#v", rows[2])
	}
	if report.Totals.DistinctBytes != 600 || report.Totals.LogicalBytes != 700 || report.Totals.SharedFiles != 1 {
		t.Fatalf("totals = %#v", report.Totals)
	}
	if report.Requests != (storage.RequestStats{Scanned: 6, Eligible: 5, Skipped: 1}) {
		t.Fatalf("requests = %#v", report.Requests)
	}
}

func TestRenderUsesHumanizedTable(t *testing.T) {
	report := storage.Report{
		Users: []storage.UserRow{{
			UserID:           1,
			DisplayName:      "One",
			Movies:           1,
			Files:            1,
			MovieBytes:       1 << 40,
			LogicalBytes:     1 << 40,
			AllocatedBytes:   1 << 40,
			AllocatedPercent: 100,
			ExclusiveBytes:   1 << 40,
		}},
		Totals: storage.Totals{
			DistinctBytes: 1 << 40,
			MovieBytes:    1 << 40,
			LogicalBytes:  1 << 40,
			Files:         1,
		},
		Requests: storage.RequestStats{Scanned: 1, Eligible: 1},
	}
	var output bytes.Buffer
	storage.Render(&output, report)
	for _, text := range []string{"1.0 TiB", "Distinct attributed storage", "One"} {
		if !bytes.Contains(output.Bytes(), []byte(text)) {
			t.Fatalf("output does not contain %q:\n%s", text, output.String())
		}
	}
}
