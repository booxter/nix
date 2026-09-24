package commanddiagnostics

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

const MaxBytes = 64 << 10

type Diagnostics struct {
	Text      string
	Truncated bool
}

type Recorder struct {
	data         []byte
	captureLimit int
	redactions   []string
	truncated    bool
	mutex        sync.Mutex
}

func NewRecorder(sensitive ...string) *Recorder {
	redactions := make([]string, 0, len(sensitive))
	longest := 0
	for _, value := range sensitive {
		if value == "" {
			continue
		}
		redactions = append(redactions, value)
		longest = max(longest, len(value))
	}
	sort.Slice(redactions, func(left, right int) bool {
		return len(redactions[left]) > len(redactions[right])
	})
	return &Recorder{
		captureLimit: MaxBytes + longest,
		redactions:   redactions,
	}
}

func (recorder *Recorder) Write(data []byte) (int, error) {
	recorder.mutex.Lock()
	defer recorder.mutex.Unlock()
	written := len(data)
	remaining := recorder.captureLimit - len(recorder.data)
	if remaining > 0 {
		recorder.data = append(recorder.data, data[:min(len(data), remaining)]...)
	}
	if len(data) > remaining {
		recorder.truncated = true
	}
	return written, nil
}

func (recorder *Recorder) Diagnostics() Diagnostics {
	if recorder == nil {
		return Diagnostics{}
	}
	recorder.mutex.Lock()
	defer recorder.mutex.Unlock()
	text := string(recorder.data)
	for _, sensitive := range recorder.redactions {
		text = strings.ReplaceAll(text, sensitive, "<media-path>")
	}
	text = strings.TrimSpace(text)
	truncated := recorder.truncated || len(text) > MaxBytes
	if len(text) > MaxBytes {
		text = text[:MaxBytes]
	}
	return Diagnostics{Text: text, Truncated: truncated}
}

type commandError struct {
	cause       error
	diagnostics Diagnostics
}

func Attach(cause error, diagnostics Diagnostics) error {
	if cause == nil && diagnostics.Text == "" {
		return nil
	}
	return &commandError{cause: cause, diagnostics: diagnostics}
}

func (err *commandError) Error() string {
	message := "command failed"
	if err.diagnostics.Text != "" {
		message += fmt.Sprintf(" with diagnostic output %q", err.diagnostics.Text)
	}
	if err.diagnostics.Truncated {
		message += " [truncated]"
	}
	return message
}

func (err *commandError) Unwrap() error { return err.cause }
