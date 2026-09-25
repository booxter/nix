package queuefinalize

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/privatefile"
	"golang.org/x/sys/unix"
)

const (
	recordVersion = "servarr-queue-finalization/v1"
	directoryName = "queue-finalizations"
	lockName      = ".lock"
)

type State string

const (
	Prepared  State = "prepared"
	Completed State = "completed"
)

type Entry struct {
	QueueID               int64
	DownloadID            string
	SubjectID             int64
	Status                string
	TrackedDownloadStatus string
}

func (entry Entry) Eligible() bool {
	return entry.QueueID > 0 && strings.TrimSpace(entry.DownloadID) != "" &&
		strings.TrimSpace(entry.DownloadID) == entry.DownloadID &&
		entry.SubjectID > 0 && entry.Status == "completed" &&
		entry.TrackedDownloadStatus == "warning"
}

type Clock interface {
	Now() time.Time
}

type Dependencies struct {
	Service        string
	StateDirectory string
	ReadQueue      func(context.Context) ([]Entry, error)
	Remove         func(context.Context, int64) error
	Clock          Clock
}

type Report struct {
	Finalized  int
	Reconciled int
}

type Finalizer struct {
	service string
	read    func(context.Context) ([]Entry, error)
	remove  func(context.Context, int64) error
	clock   Clock
	store   *store
}

func New(dependencies Dependencies) (*Finalizer, error) {
	if strings.TrimSpace(dependencies.Service) == "" || dependencies.ReadQueue == nil ||
		dependencies.Remove == nil || dependencies.Clock == nil {
		return nil, fmt.Errorf("queue finalizer dependencies are incomplete")
	}
	store, err := newStore(dependencies.StateDirectory, dependencies.Service)
	if err != nil {
		return nil, err
	}
	return &Finalizer{
		service: dependencies.Service,
		read:    dependencies.ReadQueue, remove: dependencies.Remove,
		clock: dependencies.Clock, store: store,
	}, nil
}

func (finalizer *Finalizer) Run(
	ctx context.Context,
	candidates []Entry,
	limit int,
) (Report, error) {
	if finalizer == nil || finalizer.store == nil || limit <= 0 {
		return Report{}, fmt.Errorf("queue finalizer is not configured")
	}
	for _, candidate := range candidates {
		if !candidate.Eligible() {
			return Report{}, fmt.Errorf("queue finalization candidate is ineligible")
		}
	}
	current, err := finalizer.read(ctx)
	if err != nil {
		return Report{}, fmt.Errorf("refresh %s queue before finalization: %w", finalizer.service, err)
	}
	byID := make(map[int64]Entry, len(current))
	for _, entry := range current {
		if entry.QueueID <= 0 {
			return Report{}, fmt.Errorf("%s queue contains an invalid record", finalizer.service)
		}
		if _, duplicate := byID[entry.QueueID]; duplicate {
			return Report{}, fmt.Errorf(
				"%s queue contains duplicate record ID %d", finalizer.service, entry.QueueID,
			)
		}
		byID[entry.QueueID] = entry
	}

	report := Report{}
	records, err := finalizer.store.list()
	if err != nil {
		return report, err
	}
	for _, record := range records {
		if record.State != Prepared {
			continue
		}
		if _, present := byID[record.Entry.QueueID]; present {
			continue
		}
		if err := finalizer.store.complete(record.Entry, finalizer.now()); err != nil {
			return report, err
		}
		report.Reconciled++
	}

	ordered := append([]Entry(nil), candidates...)
	sort.Slice(ordered, func(left, right int) bool {
		return ordered[left].QueueID < ordered[right].QueueID
	})
	for _, candidate := range ordered {
		if report.Finalized >= limit {
			break
		}
		observed, present := byID[candidate.QueueID]
		if !present || observed != candidate || !observed.Eligible() {
			continue
		}
		if err := finalizer.store.prepare(candidate, finalizer.now()); err != nil {
			return report, err
		}
		if err := finalizer.remove(ctx, candidate.QueueID); err != nil {
			return report, fmt.Errorf(
				"finalize %s queue record %d: %w", finalizer.service, candidate.QueueID, err,
			)
		}
		if err := finalizer.store.complete(candidate, finalizer.now()); err != nil {
			return report, err
		}
		report.Finalized++
	}
	return report, nil
}

func (finalizer *Finalizer) now() time.Time {
	return finalizer.clock.Now().UTC()
}

type record struct {
	Version    string    `json:"version"`
	Service    string    `json:"service"`
	Entry      Entry     `json:"entry"`
	State      State     `json:"state"`
	PreparedAt time.Time `json:"prepared_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

type store struct {
	service   string
	directory string
	lockPath  string
}

func newStore(root, service string) (*store, error) {
	if root == "" || !filepath.IsAbs(root) || filepath.Clean(root) != root ||
		filepath.Dir(root) == root {
		return nil, fmt.Errorf("queue finalization state directory must be an absolute clean path")
	}
	directory := filepath.Join(root, directoryName)
	if err := privatefile.EnsureDirectory(directory); err != nil {
		return nil, fmt.Errorf("prepare queue finalization state: %w", err)
	}
	return &store{
		service: service, directory: directory, lockPath: filepath.Join(directory, lockName),
	}, nil
}

func (store *store) prepare(entry Entry, at time.Time) error {
	if at.IsZero() {
		return fmt.Errorf("queue finalization time is invalid")
	}
	return store.withLock(func() error {
		previous, found, err := store.read(entry.QueueID)
		if err != nil {
			return err
		}
		if found {
			if previous.Entry != entry {
				return fmt.Errorf("queue finalization record changed identity")
			}
			return nil
		}
		return store.write(record{
			Version: recordVersion, Service: store.service, Entry: entry,
			State: Prepared, PreparedAt: at, UpdatedAt: at,
		})
	})
}

func (store *store) complete(entry Entry, at time.Time) error {
	if at.IsZero() {
		return fmt.Errorf("queue finalization time is invalid")
	}
	return store.withLock(func() error {
		previous, found, err := store.read(entry.QueueID)
		if err != nil {
			return err
		}
		if !found || previous.Entry != entry {
			return fmt.Errorf("prepared queue finalization is unavailable")
		}
		if previous.State == Completed {
			return nil
		}
		previous.State = Completed
		previous.UpdatedAt = at
		return store.write(previous)
	})
}

func (store *store) list() ([]record, error) {
	var records []record
	err := store.withLock(func() error {
		entries, err := os.ReadDir(store.directory)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
				continue
			}
			record, found, err := store.readPath(filepath.Join(store.directory, entry.Name()))
			if err != nil {
				return err
			}
			if found {
				records = append(records, record)
			}
		}
		return nil
	})
	sort.Slice(records, func(left, right int) bool {
		return records[left].Entry.QueueID < records[right].Entry.QueueID
	})
	return records, err
}

func (store *store) read(queueID int64) (record, bool, error) {
	return store.readPath(store.path(queueID))
}

func (store *store) readPath(path string) (record, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return record{}, false, nil
	}
	if err != nil {
		return record{}, false, fmt.Errorf("read queue finalization state: %w", err)
	}
	var value record
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return record{}, true, fmt.Errorf("decode queue finalization state: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return record{}, true, fmt.Errorf("decode queue finalization state: trailing data")
	}
	if err := store.validate(value); err != nil {
		return record{}, true, err
	}
	return value, true, nil
}

func (store *store) validate(value record) error {
	if value.Version != recordVersion || value.Service != store.service ||
		!value.Entry.Eligible() || value.PreparedAt.IsZero() || value.UpdatedAt.IsZero() ||
		value.UpdatedAt.Before(value.PreparedAt) ||
		(value.State != Prepared && value.State != Completed) {
		return fmt.Errorf("queue finalization state is invalid")
	}
	return nil
}

func (store *store) write(value record) error {
	if err := store.validate(value); err != nil {
		return err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode queue finalization state: %w", err)
	}
	if err := privatefile.Replace(store.directory, store.path(value.Entry.QueueID), data); err != nil {
		return fmt.Errorf("write queue finalization state: %w", err)
	}
	return nil
}

func (store *store) path(queueID int64) string {
	return filepath.Join(store.directory, fmt.Sprintf("queue-%d.json", queueID))
}

func (store *store) withLock(action func() error) error {
	fd, err := unix.Open(
		store.lockPath, unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600,
	)
	if err != nil {
		return fmt.Errorf("open queue finalization lock: %w", err)
	}
	lock := os.NewFile(uintptr(fd), store.lockPath)
	defer lock.Close()
	if err := lock.Chmod(0o600); err != nil {
		return fmt.Errorf("set queue finalization lock permissions: %w", err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		return fmt.Errorf("lock queue finalization state: %w", err)
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	return action()
}
