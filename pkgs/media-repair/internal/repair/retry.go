package repair

import (
	"errors"
	"net"
	"net/http"
	"syscall"
)

type retryableReadError struct{ cause error }

func (err *retryableReadError) Error() string { return err.cause.Error() }
func (err *retryableReadError) Unwrap() error { return err.cause }

// RetryableRead marks temporary failures from reads that can safely be repeated
// during preparation. Callers must opt in before committing any side effects.
func RetryableRead(err error) error {
	var network net.Error
	if (errors.As(err, &network) && network.Timeout()) ||
		errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ECONNRESET) {
		return &retryableReadError{cause: err}
	}

	var response interface{ HTTPStatus() int }
	if errors.As(err, &response) {
		switch response.HTTPStatus() {
		case http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusBadGateway,
			http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return &retryableReadError{cause: err}
		}
	}
	return err
}
