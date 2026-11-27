package controller

import (
	"context"
	"errors"
	"fmt"
	"time"
)

type FileProbe struct {
	FileID  FileID
	Outcome MediaProbeOutcome
}

var errCollectionTimeout = errors.New("collection time limit reached")

// WithCollectionTimeout lets probes distinguish their time budget from a
// deadline or cancellation imposed by the caller.
func WithCollectionTimeout(ctx context.Context, limit time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeoutCause(ctx, limit, errCollectionTimeout)
}

// ProbeFiles reuses results from extraction when available. Otherwise it probes
// the candidate files and records which ones the collection deadline cut short.
func (source VideoSource) ProbeFiles(
	ctx context.Context,
	reader MediaProbeReader,
) ([]FileProbe, error) {
	if source.ExistingProbes != nil {
		return source.ExistingProbes, nil
	}

	inventory := source.Inventory
	paths := make(map[FileID]string, len(inventory.Paths))
	for _, mapping := range inventory.Paths {
		if _, duplicate := paths[mapping.FileID]; duplicate {
			return nil, fmt.Errorf("inventory contains duplicate path for file %q", mapping.FileID)
		}
		paths[mapping.FileID] = mapping.AbsolutePath
	}

	probes := make([]FileProbe, 0, len(inventory.Files))
	for _, assessment := range ClassifyMediaFiles(inventory) {
		outcome, err := probeFile(ctx, assessment, paths, reader)
		if err != nil {
			return nil, err
		}
		probes = append(probes, FileProbe{FileID: assessment.File.ID, Outcome: outcome})
	}
	return probes, nil
}

// probeFile records why a file was skipped. A probe can run out of time
// before the helper starts or while the helper is reading the file.
func probeFile(
	ctx context.Context,
	assessment MediaFileAssessment,
	paths map[FileID]string,
	reader MediaProbeReader,
) (MediaProbeOutcome, error) {
	if !assessment.ProbeCandidate() {
		return UncollectedMediaProbe(MediaProbeNotCandidate), nil
	}

	err := ctx.Err()
	if err == nil {
		path, ok := paths[assessment.File.ID]
		if !ok {
			return MediaProbeOutcome{}, fmt.Errorf("candidate file %q has no local path", assessment.File.ID)
		}
		target := MediaProbeTarget{AbsolutePath: path, Fingerprint: assessment.File.Fingerprint}
		outcome, probeErr := reader.Probe(ctx, target)
		if probeErr == nil {
			return outcome, nil
		}
		err = fmt.Errorf("probe candidate file %q: %w", assessment.File.ID, probeErr)
	}

	if errors.Is(context.Cause(ctx), errCollectionTimeout) {
		return UncollectedMediaProbe(MediaProbeCollectionLimit), nil
	}
	if ctx.Err() != nil {
		return MediaProbeOutcome{}, ctx.Err()
	}
	return MediaProbeOutcome{}, err
}
