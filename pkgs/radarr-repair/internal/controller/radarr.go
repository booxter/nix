package controller

import (
	"context"
	"time"
)

type RadarrQueueReader interface {
	ReadQueue(context.Context) ([]RadarrQueueRecord, error)
}

// Keep Radarr's evolving string values instead of importing the client's enums
// into the controller. Candidate policy will interpret known values separately.
type QueueStatus string
type TrackedDownloadStatus string
type TrackedDownloadState string
type DownloadProtocol string

type RadarrStatusMessage struct {
	Title    string
	Messages []string
}

// RadarrQueueRecord is the controller's read-only observation of one queue item.
// It deliberately does not expose the third-party client's models to later stages.
type RadarrQueueRecord struct {
	ID                            int64
	MovieID                       *int64
	Title                         string
	SizeBytes                     float64
	SizeRemainingBytes            float64
	TimeRemaining                 string
	EstimatedCompletionTime       *time.Time
	Status                        QueueStatus
	TrackedDownloadStatus         TrackedDownloadStatus
	TrackedDownloadState          TrackedDownloadState
	StatusMessages                []RadarrStatusMessage
	ErrorMessage                  string
	DownloadID                    string
	Protocol                      DownloadProtocol
	DownloadClient                string
	Indexer                       string
	OutputPath                    string
	DownloadClientHasPostCategory bool
}
