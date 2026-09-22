package lidarrrepair

import (
	"reflect"
	"testing"

	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

func TestBuildImportCapabilitiesFillsOnlyMissingTracks(t *testing.T) {
	t.Parallel()
	releases := []lidarrcontracts.Release{
		{ReleaseID: 4, TrackCount: 2, Monitored: true},
		{ReleaseID: 7, TrackCount: 2},
	}
	tracks := []lidarrcontracts.Track{
		{TrackID: 5, ReleaseID: 4, HasFile: true},
		{TrackID: 6, ReleaseID: 4},
		{TrackID: 8, ReleaseID: 7},
		{TrackID: 9, ReleaseID: 7},
	}

	capabilities, err := buildImportCapabilities(3, releases, tracks, []string{"artifact:one"})
	if err != nil {
		t.Fatal(err)
	}
	if len(capabilities) != 1 || capabilities[0].ReleaseID != 4 ||
		!reflect.DeepEqual(capabilities[0].TrackIDs, []int64{6}) {
		t.Fatalf("capabilities = %#v", capabilities)
	}
}

func TestBuildImportCapabilitiesAllowsReleaseChoiceForEmptyAlbum(t *testing.T) {
	t.Parallel()
	releases := []lidarrcontracts.Release{
		{ReleaseID: 4, TrackCount: 1, Monitored: true},
		{ReleaseID: 7, TrackCount: 1},
	}
	tracks := []lidarrcontracts.Track{
		{TrackID: 5, ReleaseID: 4},
		{TrackID: 8, ReleaseID: 7},
	}

	capabilities, err := buildImportCapabilities(3, releases, tracks, []string{"artifact:one"})
	if err != nil {
		t.Fatal(err)
	}
	if len(capabilities) != 2 {
		t.Fatalf("capabilities = %#v", capabilities)
	}
}

func TestBuildImportCapabilitiesDoesNotReplaceCompleteAlbum(t *testing.T) {
	t.Parallel()
	releases := []lidarrcontracts.Release{{ReleaseID: 4, TrackCount: 1, Monitored: true}}
	tracks := []lidarrcontracts.Track{{TrackID: 5, ReleaseID: 4, HasFile: true}}

	capabilities, err := buildImportCapabilities(3, releases, tracks, []string{"artifact:one"})
	if err != nil {
		t.Fatal(err)
	}
	if len(capabilities) != 0 {
		t.Fatalf("capabilities = %#v", capabilities)
	}
}
