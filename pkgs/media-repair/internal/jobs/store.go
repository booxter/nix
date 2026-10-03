package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"path/filepath"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type Service string

const (
	Radarr Service = "radarr"
	Lidarr Service = "lidarr"
)

type State string

const (
	Observed  State = "observed"
	Ready     State = "ready"
	Running   State = "running"
	Importing State = "importing"
	Imported  State = "imported"
	Blocked   State = "blocked"
	Failed    State = "failed"
	Removed   State = "removed"
	Removing  State = "removing"
)

type Job struct {
	ID                 int64   `gorm:"primaryKey"`
	Service            Service `gorm:"uniqueIndex:queue_identity"`
	QueueID            int64   `gorm:"uniqueIndex:queue_identity"`
	DownloadID         string  `gorm:"uniqueIndex:queue_identity"`
	Title              string
	SourceFingerprint  string
	StableSince        time.Time
	Evidence           json.RawMessage `gorm:"serializer:json"`
	CollectionError    string
	Plan               json.RawMessage `gorm:"serializer:json"`
	Guidance           string
	RuntimeToleranceMS int64
	RetryAt            time.Time
	PlanningAttempts   int
	PendingAction      string
	Revision           int64
	InQueue            bool
	State              State
	Reason             string
	UpdatedAt          time.Time `gorm:"autoUpdateTime:false"`
}

type Attempt struct {
	JobID            int64 `gorm:"primaryKey;autoIncrement:false"`
	Number           int64 `gorm:"primaryKey;autoIncrement:false"`
	State            State
	Plan             json.RawMessage `gorm:"serializer:json"`
	OutputPath       string
	ImportRequest    json.RawMessage `gorm:"serializer:json"`
	HistoryIDBefore  int64
	CommandID        int64
	ImportStartedAt  time.Time
	ImportTerminalAt time.Time
	ImportReceipt    json.RawMessage `gorm:"serializer:json"`
	Reason           string
	StartedAt        time.Time
	UpdatedAt        time.Time `gorm:"autoUpdateTime:false"`
}

type Store struct{ db *gorm.DB }

// Open expects its parent directory to be private and on local storage.
func Open(path string) (*Store, error) {
	location := url.URL{Scheme: "file", Path: filepath.Clean(path)}
	location.RawQuery = url.Values{
		"_journal_mode": {"WAL"},
		"_synchronous":  {"FULL"},
		"_busy_timeout": {"5000"},
		"_txlock":       {"immediate"},
	}.Encode()
	db, err := gorm.Open(sqlite.Open(location.String()), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		return nil, err
	}

	connection, err := db.DB()
	if err != nil {
		return nil, err
	}
	connection.SetMaxOpenConns(1)
	if err := db.AutoMigrate(&Job{}, &Attempt{}); err != nil {
		connection.Close()
		return nil, err
	}

	return &Store{db: db}, nil
}

func (store *Store) Close() error {
	connection, err := store.db.DB()
	if err != nil {
		return err
	}
	return connection.Close()
}

func (store *Store) Observe(ctx context.Context, observed Job) (Job, error) {
	var job Job
	err := store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		identity := Job{Service: observed.Service, QueueID: observed.QueueID, DownloadID: observed.DownloadID}
		err := tx.Where(&identity, "Service", "QueueID", "DownloadID").First(&job).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			job = observed
			job.ID = 0
			job.State = Observed
			job.StableSince = observed.UpdatedAt
			job.InQueue = true
			return tx.Create(&job).Error
		}
		if err != nil {
			return err
		}

		job.Title = observed.Title
		job.UpdatedAt = observed.UpdatedAt
		job.InQueue = true
		job.CollectionError = observed.CollectionError
		if !active(job.State) && observed.Evidence != nil {
			if job.SourceFingerprint != observed.SourceFingerprint && job.State != Imported && job.State != Removed {
				job.Plan = nil
				job.State = Observed
				job.Reason = ""
				job.StableSince = observed.UpdatedAt
				job.RetryAt = time.Time{}
				job.PlanningAttempts = 0
			}
			job.SourceFingerprint = observed.SourceFingerprint
			job.Evidence = observed.Evidence
		}

		return tx.Save(&job).Error
	})
	return job, err
}

func (store *Store) Get(ctx context.Context, id int64) (Job, error) {
	var job Job
	err := store.db.WithContext(ctx).First(&job, id).Error
	return job, err
}

func (store *Store) List(ctx context.Context, service Service) ([]Job, error) {
	var jobs []Job
	err := store.db.WithContext(ctx).Where(&Job{Service: service}).Order("id").Find(&jobs).Error
	return jobs, err
}

// A model response may arrive after the source files changed.
func (store *Store) SetPlan(ctx context.Context, id int64, fingerprint string, plan json.RawMessage, guidance string, at time.Time) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job Job
		if err := tx.First(&job, id).Error; err != nil {
			return err
		}
		if job.SourceFingerprint != fingerprint || active(job.State) || job.State == Imported || job.State == Removed {
			return ErrConflict
		}

		job.Plan = plan
		job.Guidance = guidance
		job.UpdatedAt = at
		job.State = Ready
		job.Reason = ""
		return tx.Save(&job).Error
	})
}

func (store *Store) Start(ctx context.Context, id int64, at time.Time) (Attempt, error) {
	var attempt Attempt
	err := store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job Job
		if err := tx.First(&job, id).Error; err != nil {
			return err
		}
		if job.State != Ready || job.PendingAction != "" {
			return ErrConflict
		}

		var previous Attempt
		err := tx.Where(&Attempt{JobID: id}).Order("number DESC").First(&previous).Error
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		attempt = Attempt{
			JobID:     id,
			Number:    previous.Number + 1,
			State:     Running,
			Plan:      job.Plan,
			StartedAt: at.UTC(),
			UpdatedAt: at.UTC(),
		}
		if err := tx.Create(&attempt).Error; err != nil {
			return err
		}

		job.State = Running
		job.Reason = ""
		job.UpdatedAt = at
		return tx.Save(&job).Error
	})
	return attempt, err
}

// The attempt and its UI-visible job change together. Persist Importing before
// contacting Servarr so recovery checks for an import before resubmitting it.
func (store *Store) UpdateAttempt(ctx context.Context, attempt Attempt) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var previous Attempt
		if err := tx.Where(&Attempt{JobID: attempt.JobID, Number: attempt.Number}).First(&previous).Error; err != nil {
			return err
		}
		if !active(previous.State) {
			return ErrConflict
		}

		previous.State = attempt.State
		previous.Reason = attempt.Reason
		previous.UpdatedAt = attempt.UpdatedAt
		previous.OutputPath = attempt.OutputPath
		previous.ImportReceipt = attempt.ImportReceipt
		previous.ImportRequest = attempt.ImportRequest
		previous.HistoryIDBefore = attempt.HistoryIDBefore
		previous.CommandID = attempt.CommandID
		previous.ImportStartedAt = attempt.ImportStartedAt
		previous.ImportTerminalAt = attempt.ImportTerminalAt
		if err := tx.Save(&previous).Error; err != nil {
			return err
		}

		var job Job
		if err := tx.First(&job, attempt.JobID).Error; err != nil {
			return err
		}
		job.State = attempt.State
		job.Reason = attempt.Reason
		job.UpdatedAt = attempt.UpdatedAt
		return tx.Save(&job).Error
	})
}

func (store *Store) Attempts(ctx context.Context, id int64) ([]Attempt, error) {
	var attempts []Attempt
	err := store.db.WithContext(ctx).Where(&Attempt{JobID: id}).Order("number").Find(&attempts).Error
	return attempts, err
}

func (store *Store) LatestAttempt(ctx context.Context, id int64) (Attempt, error) {
	var attempt Attempt
	err := store.db.WithContext(ctx).Where(&Attempt{JobID: id}).Order("number DESC").First(&attempt).Error
	return attempt, err
}

var ErrConflict = errors.New("job changed or operation is not valid in its current state")

func active(state State) bool {
	return state == Running || state == Importing || state == Removing
}
