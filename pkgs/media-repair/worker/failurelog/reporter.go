package failurelog

import (
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
)

const (
	maximumErrorBytes = 16 << 10
	maximumErrorDepth = 32
)

type Event struct {
	Operation   string
	RequestID   string
	CaseID      string
	ExecutionID string
	Reason      string
	Cause       error
}

type Reporter interface {
	Report(Event)
}

type Writer struct {
	output io.Writer
	mutex  sync.Mutex
}

func NewWriter(output io.Writer) (*Writer, error) {
	if output == nil {
		return nil, fmt.Errorf("worker failure log output is required")
	}
	return &Writer{output: output}, nil
}

func (reporter *Writer) Report(event Event) {
	if reporter == nil || reporter.output == nil || event.Cause == nil {
		return
	}
	line := fmt.Sprintf(
		"media repair worker failure operation=%s request_id=%s case_id=%s execution_id=%s reason=%s error=%s\n",
		strconv.Quote(event.Operation),
		strconv.Quote(event.RequestID),
		strconv.Quote(event.CaseID),
		strconv.Quote(event.ExecutionID),
		strconv.Quote(event.Reason),
		strconv.Quote(errorChain(event.Cause)),
	)
	reporter.mutex.Lock()
	defer reporter.mutex.Unlock()
	_, _ = io.WriteString(reporter.output, line)
}

func errorChain(err error) string {
	var output strings.Builder
	appendError(&output, err, 0)
	text := output.String()
	if len(text) <= maximumErrorBytes {
		return text
	}
	return text[:maximumErrorBytes] + " [truncated]"
}

func appendError(output *strings.Builder, err error, depth int) {
	if err == nil {
		return
	}
	if depth >= maximumErrorDepth {
		output.WriteString("[error chain truncated]")
		return
	}
	message := err.Error()
	output.WriteString(message)
	if multiple, ok := err.(interface{ Unwrap() []error }); ok {
		for _, cause := range multiple.Unwrap() {
			output.WriteString("; caused by: ")
			appendError(output, cause, depth+1)
		}
		return
	}
	if single, ok := err.(interface{ Unwrap() error }); ok && single.Unwrap() != nil {
		cause := single.Unwrap()
		if strings.HasSuffix(message, cause.Error()) {
			appendNestedCause(output, cause, depth+1)
		} else {
			output.WriteString(": ")
			appendError(output, cause, depth+1)
		}
	}
}

func appendNestedCause(output *strings.Builder, err error, depth int) {
	if depth >= maximumErrorDepth {
		output.WriteString(": [error chain truncated]")
		return
	}
	if single, ok := err.(interface{ Unwrap() error }); ok && single.Unwrap() != nil {
		cause := single.Unwrap()
		if strings.HasSuffix(err.Error(), cause.Error()) {
			appendNestedCause(output, cause, depth+1)
		} else {
			output.WriteString(": ")
			appendError(output, cause, depth+1)
		}
	}
}
