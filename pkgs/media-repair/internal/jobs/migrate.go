package jobs

import (
	"context"
	"fmt"

	"gorm.io/gorm"
)

// MigratedJob is used only by the one-time JSON-state converter. Importing the
// complete batch in one transaction leaves an empty database if conversion fails.
type MigratedJob struct {
	Job      Job
	Attempts []Attempt
}

func (store *Store) Import(ctx context.Context, batch []MigratedJob) error {
	return store.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var count int64
		if err := tx.Model(&Job{}).Count(&count).Error; err != nil {
			return err
		}
		if count != 0 {
			return fmt.Errorf("conversion requires an empty jobs database")
		}

		for _, entry := range batch {
			job := entry.Job
			job.ID = 0
			if err := tx.Create(&job).Error; err != nil {
				return err
			}
			for index, attempt := range entry.Attempts {
				attempt.JobID = job.ID
				attempt.Number = int64(index + 1)
				if err := tx.Create(&attempt).Error; err != nil {
					return err
				}
			}
		}
		return nil
	})
}
