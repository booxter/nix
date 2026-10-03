package statemigration

import (
	"encoding/json"
	"fmt"
	"path/filepath"

	"github.com/booxter/nix-config/media-repair/contracts"
	"github.com/booxter/nix-config/media-repair/internal/casestore"
	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/repairradarr"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

type convertedCase struct {
	id      string
	job     jobs.Job
	attempt *jobs.Attempt
}

type lidarrCase struct {
	lidarrrepair.Record
	CaseID string `json:"case_id"`
}

func radarrCases(directory string) ([]convertedCase, error) {
	records, err := readDirectory[casestore.CaseRecord](filepath.Join(directory, "cases"))
	if err != nil {
		return nil, err
	}
	var result []convertedCase
	for _, record := range records {
		var request contracts.RepairCaseV3
		if err := json.Unmarshal(record.Request, &request); err != nil {
			return nil, fmt.Errorf("Radarr case %s: %w", record.CaseID, err)
		}
		evidence, err := json.Marshal(repairradarr.Evidence{Case: request, Snapshot: record.Snapshot})
		if err != nil {
			return nil, err
		}
		queue := record.Snapshot.Observation.Correlation.Radarr
		job := jobs.Job{
			Service:           jobs.Radarr,
			QueueID:           queue.ID,
			DownloadID:        queue.DownloadID,
			Title:             queue.Title,
			State:             jobs.Observed,
			SourceFingerprint: record.CaseID,
			StableSince:       record.StableSince,
			Evidence:          evidence,
			UpdatedAt:         request.ObservedAt,
		}
		if job.StableSince.IsZero() {
			job.StableSince = job.UpdatedAt
		}
		result = append(result, convertedCase{id: record.CaseID, job: job})
	}
	return result, nil
}

func lidarrCases(directory string) ([]convertedCase, error) {
	records, err := readDirectory[lidarrCase](filepath.Join(directory, "cases"))
	if err != nil {
		return nil, err
	}
	var result []convertedCase
	for _, record := range records {
		var request lidarrcontracts.Case
		if err := json.Unmarshal(record.Case, &request); err != nil {
			return nil, fmt.Errorf("Lidarr case %s: %w", record.CaseID, err)
		}
		if len(record.Bindings) == 0 || record.Bindings[0].DownloadID == "" {
			return nil, fmt.Errorf("Lidarr case %s has no download identity", record.CaseID)
		}
		downloadID := record.Bindings[0].DownloadID
		for _, binding := range record.Bindings {
			if binding.DownloadID != downloadID {
				return nil, fmt.Errorf("Lidarr case %s has conflicting download identities", record.CaseID)
			}
		}
		evidence, err := json.Marshal(record.Record)
		if err != nil {
			return nil, err
		}
		result = append(result, convertedCase{
			id: record.CaseID,
			job: jobs.Job{
				Service:           jobs.Lidarr,
				QueueID:           record.QueueID,
				DownloadID:        downloadID,
				Title:             request.Queue.Title,
				State:             jobs.Observed,
				SourceFingerprint: record.CaseID,
				StableSince:       request.ObservedAt,
				Evidence:          evidence,
				UpdatedAt:         request.ObservedAt,
			},
		})
	}
	return appendOrphanImports(directory, result)
}

func appendOrphanImports(directory string, cases []convertedCase) ([]convertedCase, error) {
	records, err := readDirectory[lidarrrepair.ImportExecution](filepath.Join(directory, "imports"))
	if err != nil {
		return nil, err
	}
	known := make(map[string]bool, len(cases))
	for _, current := range cases {
		known[current.id] = true
	}
	for _, record := range records {
		if known[record.CaseID] {
			continue
		}
		if len(record.Tracks) == 0 {
			return nil, fmt.Errorf("orphan Lidarr import %s has no track identity", record.CaseID)
		}
		// A completed import can outlive its planning case. Its receipt is
		// still history and must not disappear just because that case is gone.
		cases = append(cases, convertedCase{
			id: record.CaseID,
			job: jobs.Job{
				Service:    jobs.Lidarr,
				QueueID:    record.QueueID,
				DownloadID: record.Tracks[0].DownloadID,
				Title:      fmt.Sprintf("Imported album #%d", record.AlbumID),
				UpdatedAt:  record.UpdatedAt,
			},
		})
	}
	return cases, nil
}
