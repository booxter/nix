package statemigration

import (
	"fmt"
	"path/filepath"
	"sort"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/queueaction"
	"github.com/booxter/nix-config/media-repair/internal/review"
)

func Convert(root string, mediaRoots map[string]string) ([]jobs.MigratedJob, error) {
	var batch []jobs.MigratedJob
	for _, service := range []jobs.Service{jobs.Radarr, jobs.Lidarr} {
		directory := filepath.Join(root, string(service)+"-repair-controller")
		var cases []convertedCase
		var err error
		if service == jobs.Radarr {
			cases, err = radarrCases(directory)
		} else {
			cases, err = lidarrCases(directory)
		}
		if err != nil {
			return nil, err
		}

		byCase := make(map[string]*convertedCase, len(cases))
		for index := range cases {
			current := &cases[index]
			byCase[current.id] = current
			if err := restorePlan(directory, current); err != nil {
				return nil, err
			}
			if err := restoreAttempt(directory, mediaRoots, current); err != nil {
				return nil, err
			}
		}
		if err := restoreGuidance(root, directory, service, byCase); err != nil {
			return nil, err
		}

		grouped := groupCases(cases)
		if err := restoreReview(root, service, grouped, byCase); err != nil {
			return nil, err
		}
		if err := restoreRemovals(root, directory, service, grouped); err != nil {
			return nil, err
		}
		for _, entry := range grouped {
			batch = append(batch, *entry)
		}
	}
	sort.Slice(batch, func(i, j int) bool {
		if batch[i].Job.Service != batch[j].Job.Service {
			return batch[i].Job.Service < batch[j].Job.Service
		}
		if batch[i].Job.QueueID != batch[j].Job.QueueID {
			return batch[i].Job.QueueID < batch[j].Job.QueueID
		}
		return batch[i].Job.DownloadID < batch[j].Job.DownloadID
	})
	return batch, nil
}

func groupCases(cases []convertedCase) map[jobs.QueueKey]*jobs.MigratedJob {
	sort.Slice(cases, func(i, j int) bool {
		return cases[i].job.UpdatedAt.Before(cases[j].job.UpdatedAt)
	})
	grouped := make(map[jobs.QueueKey]*jobs.MigratedJob)
	for _, current := range cases {
		key := jobs.QueueKey{QueueID: current.job.QueueID, DownloadID: current.job.DownloadID}
		entry := grouped[key]
		if entry == nil {
			entry = &jobs.MigratedJob{}
			grouped[key] = entry
		}
		entry.Job = current.job
		if current.attempt != nil {
			entry.Attempts = append(entry.Attempts, *current.attempt)
		}
	}
	for _, entry := range grouped {
		sort.Slice(entry.Attempts, func(i, j int) bool {
			return entry.Attempts[i].StartedAt.Before(entry.Attempts[j].StartedAt)
		})
		for _, attempt := range entry.Attempts {
			if attempt.State == jobs.Imported {
				entry.Job.State = jobs.Imported
				entry.Job.PendingAction = ""
				entry.Job.Reason = ""
			}
		}
	}
	return grouped
}

func restoreReview(
	root string,
	service jobs.Service,
	grouped map[jobs.QueueKey]*jobs.MigratedJob,
	cases map[string]*convertedCase,
) error {
	snapshot, _, err := readJSON[review.Snapshot](filepath.Join(root, "media-repair-review", string(service), "snapshot.json"))
	if err != nil {
		return err
	}
	for _, item := range snapshot.Current {
		if item.QueueIdentity == nil {
			continue
		}
		key := jobs.QueueKey{QueueID: item.QueueID, DownloadID: item.QueueIdentity.DownloadID}
		entry := grouped[key]
		if entry == nil {
			entry = &jobs.MigratedJob{Job: jobs.Job{
				Service:    service,
				QueueID:    item.QueueID,
				DownloadID: item.QueueIdentity.DownloadID,
				Title:      item.Title,
				State:      jobs.Observed,
				UpdatedAt:  item.LastSeenAt,
			}}
			grouped[key] = entry
		}
		if current := cases[item.CaseID]; current != nil {
			// A late response for an older case must not select obsolete source
			// evidence over the case that the controller currently displays.
			imported := entry.Job.State == jobs.Imported
			entry.Job = current.job
			if imported {
				entry.Job.State = jobs.Imported
				entry.Job.PendingAction = ""
			}
		}
		entry.Job.InQueue = true
		if entry.Job.State == jobs.Imported || entry.Job.State == jobs.Failed || entry.Job.PendingAction == jobs.Reconsider {
			continue
		}
		if item.ExecutionBlock != nil {
			entry.Job.State = jobs.Blocked
			entry.Job.Reason = item.ExecutionBlock.Reason
		}
		if item.ExecutionFailure != "" {
			entry.Job.State = jobs.Failed
			entry.Job.Reason = item.ExecutionFailure
		}
	}
	return nil
}

func restoreRemovals(root, directory string, service jobs.Service, grouped map[jobs.QueueKey]*jobs.MigratedJob) error {
	requests, err := readDirectory[queueaction.Request](filepath.Join(root, "media-repair-actions", string(service)))
	if err != nil {
		return err
	}
	sort.Slice(requests, func(i, j int) bool {
		return requests[i].CreatedAt.Before(requests[j].CreatedAt)
	})
	for _, request := range requests {
		key := jobs.QueueKey{QueueID: request.Queue.QueueID, DownloadID: request.Queue.DownloadID}
		entry := grouped[key]
		if entry == nil {
			return fmt.Errorf("queue action %s has no matching job", request.RequestID)
		}
		result, found, err := readJSON[queueaction.Result](recordPath(filepath.Join(directory, "queue-action-results"), request.RequestID))
		if err != nil {
			return err
		}
		job := &entry.Job
		job.PendingAction = jobs.Delete
		if found && result.State == queueaction.StateCompleted {
			job.State = jobs.Removed
			job.PendingAction = ""
			job.InQueue = false
			job.Reason = "queue tracking removed; media retained"
		} else if found {
			job.Reason = result.Failure
		}
	}
	return nil
}
