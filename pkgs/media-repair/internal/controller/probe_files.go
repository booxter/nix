package controller

import (
	"context"
	"errors"
	"fmt"
)

type FileProbe struct {
	FileID  FileID
	Outcome MediaProbeOutcome
}

// ProbeFiles reuses results from extraction when available. Otherwise it probes
// the candidate files and records which ones the collection deadline cut short.
func (source VideoSource) ProbeFiles(
	callerContext context.Context,
	collectionContext context.Context,
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
		outcome, err := probeFile(callerContext, collectionContext, assessment, paths, reader)
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
	scanCtx, probeCtx context.Context,
	assessment MediaFileAssessment,
	paths map[FileID]string,
	reader MediaProbeReader,
) (MediaProbeOutcome, error) {
	if !assessment.ProbeCandidate() {
		return UncollectedMediaProbe(MediaProbeNotCandidate), nil
	}

	err := probeCtx.Err()
	if err == nil {
		path, ok := paths[assessment.File.ID]
		if !ok {
			return MediaProbeOutcome{}, fmt.Errorf("candidate file %q has no local path", assessment.File.ID)
		}
		target := MediaProbeTarget{AbsolutePath: path, Fingerprint: assessment.File.Fingerprint}
		outcome, probeErr := reader.Probe(probeCtx, target)
		if probeErr == nil {
			return outcome, nil
		}
		err = fmt.Errorf("probe candidate file %q: %w", assessment.File.ID, probeErr)
	}

	if scanErr := scanCtx.Err(); scanErr != nil {
		return MediaProbeOutcome{}, scanErr
	}
	if errors.Is(probeCtx.Err(), context.DeadlineExceeded) {
		return UncollectedMediaProbe(MediaProbeCollectionLimit), nil
	}
	return MediaProbeOutcome{}, err
}
