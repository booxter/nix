package casestore

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

const executionLockFileName = ".execution.lock"

var ErrExecutionInProgress = errors.New("repair execution already in progress")

type ExecutionLease struct {
	lock *os.File
}

func (store *Store) AcquireExecution() (*ExecutionLease, error) {
	lock, err := store.openLock(executionLockFileName, "repair execution lock")
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		if errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN) {
			return nil, ErrExecutionInProgress
		}
		return nil, fmt.Errorf("lock repair execution: %w", err)
	}
	return &ExecutionLease{lock: lock}, nil
}

func (lease *ExecutionLease) Release() {
	if lease == nil || lease.lock == nil {
		return
	}
	unlock(lease.lock)
	lease.lock = nil
}
