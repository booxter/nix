package repair

import (
	"errors"
	"net"
	"net/http"
	"syscall"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

type preparationRetry struct {
	cause error
	at    time.Time
}

func (err *preparationRetry) Error() string { return err.cause.Error() }
func (err *preparationRetry) Unwrap() error { return err.cause }

// Give the media service time to finish its own pending import before Repairr takes over.
type ImportGracePeriod struct {
	Duration time.Duration
	Now      func() time.Time
}

func (grace ImportGracePeriod) Ready(job jobs.Job) bool {
	return grace.CheckImportState(job.TrackedDownloadState, job.StableSince) == nil
}

// Authorization checks the live queue again because its state can change after a poll.
func (grace ImportGracePeriod) CheckImportState(state string, stableSince time.Time) error {
	if state == "importPending" {
		deadline := stableSince.Add(grace.Duration)
		if grace.Now().Before(deadline) {
			return &preparationRetry{cause: errors.New("waiting for the media service to import"), at: deadline}
		}
	}
	return nil
}

// RetryableRead marks temporary failures from reads that can safely be repeated
// during preparation. Callers must opt in before committing any side effects.
func RetryableRead(err error) error {
	var network net.Error
	if (errors.As(err, &network) && network.Timeout()) ||
		errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ECONNRESET) {
		return &preparationRetry{cause: err}
	}

	var response interface{ HTTPStatus() int }
	if errors.As(err, &response) {
		switch response.HTTPStatus() {
		case http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusBadGateway,
			http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return &preparationRetry{cause: err}
		}
	}
	return err
}
