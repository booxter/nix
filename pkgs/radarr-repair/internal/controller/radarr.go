package controller

import (
	"context"
	"time"
)

type RadarrQueueReader interface {
	ReadQueue(context.Context) ([]RadarrQueueRecord, error)
}

type RadarrMovieReader interface {
	ReadMovie(context.Context, int64) (RadarrMovie, error)
}

type RadarrHistoryReader interface {
	ReadHistory(context.Context, int64, string) ([]RadarrHistoryEvent, error)
}

type RadarrManualImportReader interface {
	ReadManualImports(context.Context, RadarrManualImportQuery) ([]RadarrManualImport, error)
}

type RadarrImportedFileReader interface {
	ReadImportedFiles(context.Context, int64, string) ([]RadarrImportedFile, error)
}

// Keep Radarr's evolving string values instead of importing the client's enums
// into the controller. Candidate policy will interpret known values separately.
type QueueStatus string
type TrackedDownloadStatus string
type TrackedDownloadState string
type DownloadProtocol string
type RadarrHistoryEventType string
type RadarrManualImportRejectionType string

type RadarrManualImportQuery struct {
	MovieID    int64
	DownloadID string
	Folder     string
}

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

type RadarrMovie struct {
	ID              int64
	TMDBID          int64
	HasFile         bool
	IMDbID          *string
	Title           string
	OriginalTitle   *string
	AlternateTitles []string
	Year            int
	RuntimeMinutes  *int
}

type RadarrHistoryEvent struct {
	ID          int64
	MovieID     int64
	DownloadID  string
	EventType   RadarrHistoryEventType
	OccurredAt  time.Time
	SourceTitle string
	Quality     *RadarrQualityModel
	Languages   []RadarrLanguage
}

// RadarrImportedFile is private execution evidence from Radarr history. It is
// deliberately separate from RadarrHistoryEvent so library paths never enter a
// planner case or alter its identity.
type RadarrImportedFile struct {
	HistoryID    int64
	MovieFileID  int64
	MovieID      int64
	DownloadID   string
	OccurredAt   time.Time
	DroppedPath  string
	ImportedPath string
}

type RadarrQuality struct {
	ID         int64
	Name       string
	Source     string
	Resolution int
	Modifier   string
}

type RadarrQualityRevision struct {
	Version  int64
	Real     int64
	IsRepack bool
}

type RadarrQualityModel struct {
	Quality  RadarrQuality
	Revision *RadarrQualityRevision
}

type RadarrLanguage struct {
	ID   int64
	Name string
}

type RadarrManualImport struct {
	Path         string
	RelativePath string
	FolderName   string
	SizeBytes    int64
	MovieID      int64
	DownloadID   string
	Quality      *RadarrQualityModel
	Languages    []RadarrLanguage
	ReleaseGroup string
	IndexerFlags int64
	Rejections   []RadarrManualImportRejection
}

type RadarrManualImportRejection struct {
	Type   RadarrManualImportRejectionType
	Reason string
}
