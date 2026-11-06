package repairlidarr

import (
	"testing"
	"time"

	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestPlanningFingerprint(t *testing.T) {
	base := lidarrcontracts.Case{
		Album:     lidarrcontracts.Album{AlbumID: 1},
		Releases:  []lidarrcontracts.Release{{ReleaseID: 1}, {ReleaseID: 2}},
		Tracks:    []lidarrcontracts.Track{{TrackID: 1}, {TrackID: 2}},
		Artifacts: []lidarrcontracts.Artifact{{ArtifactID: "a"}, {ArtifactID: "b"}},
	}
	baseline, err := planningFingerprint(base)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name       string
		change     func(*lidarrcontracts.Case)
		wantChange string
	}{
		{"observation noise", func(c *lidarrcontracts.Case) {
			c.CaseID = "different"
			c.ObservedAt = time.Now()
			c.Queue.Title = "different"
			c.Queue.Messages = []string{"rejected"}
			c.Assessments = []lidarrcontracts.Assessment{{TrackIDs: []int64{42}, Rejections: []string{"rejected"}}}
			c.Capabilities = []lidarrcontracts.Capability{{TrackIDs: []int64{42}}}
		}, ""},
		{"catalog order", func(c *lidarrcontracts.Case) {
			c.Releases[0], c.Releases[1] = c.Releases[1], c.Releases[0]
			c.Tracks[0], c.Tracks[1] = c.Tracks[1], c.Tracks[0]
			c.Artifacts[0], c.Artifacts[1] = c.Artifacts[1], c.Artifacts[0]
		}, ""},
		{"album", func(c *lidarrcontracts.Case) { c.Album.AlbumID++ }, "target album"},
		{"release", func(c *lidarrcontracts.Case) { c.Releases[0].Title = "new" }, "release catalog"},
		{"track", func(c *lidarrcontracts.Case) { c.Tracks[0].HasFile = true }, "track catalog/status"},
		{"audio", func(c *lidarrcontracts.Case) { c.Artifacts[0].Fingerprint = "new" }, "audio files"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			current := base
			current.Releases = append([]lidarrcontracts.Release(nil), base.Releases...)
			current.Tracks = append([]lidarrcontracts.Track(nil), base.Tracks...)
			current.Artifacts = append([]lidarrcontracts.Artifact(nil), base.Artifacts...)
			test.change(&current)
			fingerprint, err := planningFingerprint(current)
			if err != nil {
				t.Fatal(err)
			}
			if (fingerprint != baseline) != (test.wantChange != "") {
				t.Fatalf("fingerprint change = %v, want %v", fingerprint != baseline, test.wantChange != "")
			}
			if change := planningChange(base, current); change != test.wantChange {
				t.Fatalf("change = %q, want %q", change, test.wantChange)
			}
		})
	}
}
