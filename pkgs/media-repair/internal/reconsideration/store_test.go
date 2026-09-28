package reconsideration

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testCaseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func TestStoreSubmitsAndReturnsLatestRequest(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	store, err := NewStore(directory, ServiceRadarr)
	if err != nil {
		t.Fatal(err)
	}
	first := testRequest(t, "Check the authored part order.", time.Date(2026, 9, 28, 1, 0, 0, 0, time.UTC))
	second := testRequest(t, "Compare the chapter structure too.", first.CreatedAt.Add(time.Minute))
	for _, request := range []Request{second, first} {
		created, err := store.Submit(request)
		if err != nil || !created {
			t.Fatalf("submit: created = %t, error = %v", created, err)
		}
	}
	if created, err := store.Submit(second); err != nil || created {
		t.Fatalf("duplicate: created = %t, error = %v", created, err)
	}
	latest, found, err := store.Latest(testCaseID)
	if err != nil || !found || latest != second {
		t.Fatalf("latest = %#v, found = %t, error = %v", latest, found, err)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 2 {
		t.Fatalf("entries = %d, error = %v", len(entries), err)
	}
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil || info.Mode().Perm() != 0o640 {
			t.Fatalf("mode = %v, error = %v", info.Mode().Perm(), err)
		}
	}
}

func TestStoreRejectsMalformedRequestFiles(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	store, err := NewStore(directory, ServiceRadarr)
	if err != nil {
		t.Fatal(err)
	}
	request := testRequest(t, "Review the selected title.", time.Date(2026, 9, 28, 1, 0, 0, 0, time.UTC))
	path := filepath.Join(directory, requestFileName(request))
	if err := os.WriteFile(path, []byte(`{"version":"bad"}`), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Latest(testCaseID); err == nil {
		t.Fatal("malformed request was accepted")
	}
}

func TestRequestValidation(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 28, 1, 0, 0, 0, time.UTC)
	tests := []struct {
		name     string
		service  Service
		caseID   string
		guidance string
	}{
		{name: "service", service: "sonarr", caseID: testCaseID, guidance: "Review it."},
		{name: "case", service: ServiceRadarr, caseID: "case", guidance: "Review it."},
		{name: "empty", service: ServiceRadarr, caseID: testCaseID},
		{name: "space", service: ServiceRadarr, caseID: testCaseID, guidance: " Review it."},
		{name: "control", service: ServiceRadarr, caseID: testCaseID, guidance: "Review\u0000it."},
		{name: "long", service: ServiceRadarr, caseID: testCaseID, guidance: strings.Repeat("a", MaximumGuidanceLen+1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := NewRequest(test.service, test.caseID, test.guidance, now); err == nil {
				t.Fatal("invalid request was accepted")
			}
		})
	}
}

func testRequest(t *testing.T, guidance string, createdAt time.Time) Request {
	t.Helper()
	request, err := NewRequest(ServiceRadarr, testCaseID, guidance, createdAt)
	if err != nil {
		t.Fatal(err)
	}
	return request
}
