package lidarrrepair

import (
	"context"
	"fmt"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

type Lidarr interface {
	ReadQueue(context.Context) ([]lidarr.QueueRecord, error)
	RecoverAlbumIdentity(context.Context, string) (lidarr.AlbumIdentity, bool, error)
	ReadAlbum(context.Context, int64) (lidarr.Album, error)
	ReadReleaseTracks(context.Context, int64, int64) ([]lidarr.Track, error)
	ReadManualImports(context.Context, lidarr.ManualImportQuery) ([]lidarr.ManualImport, error)
}

type Planner interface {
	PlanLidarr(context.Context, lidarrcontracts.Case, planning.Options) (lidarrcontracts.Decision, error)
}

type ImportClient interface {
	RequestManualImport(context.Context, lidarr.ManualImportCommand) (servarr.Command, error)
	ReadManualImportCommand(context.Context, int64) (servarr.Command, error)
	ReadImportedTracks(context.Context, int64, string) ([]lidarr.ImportedTrack, error)
}

type Evidence struct {
	Queue             lidarr.QueueRecord
	SourceKind        SourceKind
	SourcePath        string
	SourceFingerprint string
	WorkspaceRoot     string
	Case              lidarrcontracts.Case
	Bindings          []ImportBinding
	Recovered         bool
}

type EvidenceCollector struct {
	lidarr Lidarr
	worker Worker

	now func() time.Time
}

func NewEvidenceCollector(client Lidarr, worker Worker) *EvidenceCollector {
	return &EvidenceCollector{lidarr: client, worker: worker, now: time.Now}
}

// Even when the files come from a saved workspace, ask Lidarr which tracks
// are missing today and how it would import each file.
func (inspection albumInspection) collectEvidence(ctx context.Context, queue lidarr.QueueRecord) (Evidence, error) {
	workspace, err := inspection.prepareWorkspace(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}

	album, tracks, err := inspection.readCatalog(ctx, queue)
	if err != nil {
		return Evidence{}, err
	}
	imports, err := inspection.lidarr.ReadManualImports(ctx, lidarr.ManualImportQuery{
		Folder: workspace.root, ArtistID: *queue.ArtistID,
	})
	if err != nil {
		return Evidence{}, fmt.Errorf("read manual imports: %w", err)
	}

	repairCase, bindings, err := assembleAlbum(inspection.now(), queue, album, tracks, workspace, imports)
	if err != nil {
		return Evidence{}, fmt.Errorf("assemble album case: %w", err)
	}
	return Evidence{
		Queue: queue, Case: repairCase, Bindings: bindings,
		SourceKind: workspace.sourceKind, SourcePath: workspace.sourcePath,
		SourceFingerprint: workspace.fingerprint, WorkspaceRoot: workspace.root,
		Recovered: workspace.recovered,
	}, nil
}

func (collector *EvidenceCollector) readCatalog(
	ctx context.Context,
	queue lidarr.QueueRecord,
) (lidarr.Album, []lidarr.Track, error) {
	album, err := collector.lidarr.ReadAlbum(ctx, *queue.AlbumID)
	if err != nil {
		return lidarr.Album{}, nil, fmt.Errorf("read album: %w", err)
	}
	var tracks []lidarr.Track
	for _, release := range album.Releases {
		releaseTracks, readErr := collector.lidarr.ReadReleaseTracks(ctx, album.ID, release.ID)
		if readErr != nil {
			return lidarr.Album{}, nil, fmt.Errorf(
				"read release %d tracks: %w", release.ID, readErr,
			)
		}
		tracks = append(tracks, releaseTracks...)
	}
	return album, tracks, nil
}
