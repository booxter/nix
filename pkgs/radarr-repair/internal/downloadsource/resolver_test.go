package downloadsource

import (
	"context"
	"errors"
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
)

func TestResolverSelectsExactSourcePair(t *testing.T) {
	t.Parallel()

	transmission := &fakeReader{download: controller.Download{ID: "torrent-id"}, found: true}
	sabnzbd := &fakeReader{download: controller.Download{ID: "sab-id"}, found: true}
	resolver, err := New(
		Registration{Protocol: "torrent", ClientName: "Transmission", Reader: transmission},
		Registration{Protocol: "usenet", ClientName: "SABnzbd", Reader: sabnzbd},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !resolver.Supports("torrent", "Transmission") ||
		!resolver.Supports("usenet", "SABnzbd") ||
		resolver.Supports("usenet", "Transmission") ||
		resolver.Supports("usenet", "sabnzbd") {
		t.Fatal("resolver did not use exact protocol and client-name pairs")
	}

	download, found, err := resolver.Resolve(context.Background(), controller.RadarrQueueRecord{
		Protocol: "usenet", DownloadClient: "SABnzbd", DownloadID: "sab-id",
	})
	if err != nil || !found || download.ID != "sab-id" {
		t.Fatalf("resolved download = %#v, %t, %v", download, found, err)
	}
	if sabnzbd.downloadID != "sab-id" || transmission.downloadID != "" {
		t.Fatalf("reader calls = %q, %q", transmission.downloadID, sabnzbd.downloadID)
	}
}

func TestResolverRejectsInvalidRegistrations(t *testing.T) {
	t.Parallel()

	reader := &fakeReader{}
	tests := []struct {
		name          string
		registrations []Registration
	}{
		{name: "empty"},
		{name: "protocol", registrations: []Registration{{ClientName: "SABnzbd", Reader: reader}}},
		{name: "client", registrations: []Registration{{Protocol: "usenet", Reader: reader}}},
		{name: "reader", registrations: []Registration{{Protocol: "usenet", ClientName: "SABnzbd"}}},
		{name: "duplicate", registrations: []Registration{
			{Protocol: "usenet", ClientName: "SABnzbd", Reader: reader},
			{Protocol: "usenet", ClientName: "SABnzbd", Reader: reader},
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := New(test.registrations...); err == nil {
				t.Fatal("invalid source registrations were accepted")
			}
		})
	}
}

func TestResolverPropagatesReaderResult(t *testing.T) {
	t.Parallel()

	want := errors.New("reader failed")
	resolver, err := New(Registration{
		Protocol: "usenet", ClientName: "SABnzbd", Reader: &fakeReader{err: want},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = resolver.Resolve(context.Background(), controller.RadarrQueueRecord{
		Protocol: "usenet", DownloadClient: "SABnzbd", DownloadID: "sab-id",
	})
	if !errors.Is(err, want) {
		t.Fatalf("resolve error = %v", err)
	}
	_, _, err = resolver.Resolve(context.Background(), controller.RadarrQueueRecord{
		Protocol: "usenet", DownloadClient: "Other", DownloadID: "sab-id",
	})
	if err == nil {
		t.Fatal("unsupported source was resolved")
	}
}

type fakeReader struct {
	download   controller.Download
	found      bool
	err        error
	downloadID string
}

func (reader *fakeReader) FindDownload(
	_ context.Context,
	downloadID string,
) (controller.Download, bool, error) {
	reader.downloadID = downloadID
	return reader.download, reader.found, reader.err
}
