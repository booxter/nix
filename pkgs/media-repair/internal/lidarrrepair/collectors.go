package lidarrrepair

import (
	"context"
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/pipeline"
)

var albumCollectors = pipeline.Collectors[collectionInput, albumFacts]{
	collectCatalog,
	collectManualImports,
}

type collectionInput struct {
	client      Lidarr
	albumID     int64
	importQuery lidarr.ManualImportQuery
}

type albumFacts struct {
	album   lidarr.Album
	tracks  []lidarr.Track
	imports []lidarr.ManualImport
}

type addFact = pipeline.AddFact[albumFacts]

// Lidarr lists tracks by release. Read every release so the planner sees
// which tracks are missing from each edition of the album.
func collectCatalog(ctx context.Context, in collectionInput) (addFact, error) {
	album, err := in.client.ReadAlbum(ctx, in.albumID)
	if err != nil {
		return nil, fmt.Errorf("read album: %w", err)
	}

	var tracks []lidarr.Track
	for _, release := range album.Releases {
		releaseTracks, err := in.client.ReadReleaseTracks(ctx, album.ID, release.ID)
		if err != nil {
			return nil, fmt.Errorf("read release %d tracks: %w", release.ID, err)
		}
		tracks = append(tracks, releaseTracks...)
	}
	return func(facts *albumFacts) {
		facts.album = album
		facts.tracks = tracks
	}, nil
}

func collectManualImports(ctx context.Context, in collectionInput) (addFact, error) {
	imports, err := in.client.ReadManualImports(ctx, in.importQuery)
	if err != nil {
		return nil, fmt.Errorf("read manual imports: %w", err)
	}
	return func(facts *albumFacts) { facts.imports = imports }, nil
}
