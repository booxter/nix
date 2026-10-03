package repair

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

type Observation struct {
	Jobs     []jobs.Job
	Queue    []jobs.QueueKey
	Complete []jobs.QueueKey
}

type Decision struct {
	Data   json.RawMessage
	Repair bool
	Reason string
}

type Service interface {
	Adapter
	Observe(context.Context, []jobs.Job) (Observation, error)
	Plan(context.Context, jobs.Job) (Decision, error)
	Ready(jobs.Job) bool
	Remove(context.Context, jobs.Job) error
}

type Scheduler struct {
	Store    *jobs.Store
	Service  Service
	Name     jobs.Service
	Now      func() time.Time
	Interval time.Duration
	Wake     <-chan struct{}
	Disabled func() (bool, error)
	Log      *slog.Logger
}

func (scheduler *Scheduler) Run(ctx context.Context) {
	workWake := make(chan struct{}, 1)
	actionsDone := make(chan struct{})
	go func() {
		defer close(actionsDone)
		scheduler.runActions(ctx, workWake)
	}()
	defer func() { <-actionsDone }()

	nextObservation := time.Time{}
	timer := time.NewTimer(0)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-workWake:
		case <-timer.C:
		}

		now := scheduler.Now()
		if !now.Before(nextObservation) {
			if err := scheduler.observe(ctx); err != nil {
				scheduler.Log.Error("observe queue", "service", scheduler.Name, "error", err)
			}
			nextObservation = now.Add(scheduler.Interval)
		}

		if err := scheduler.advance(ctx); err != nil && ctx.Err() == nil {
			scheduler.Log.Error("advance repairs", "service", scheduler.Name, "error", err)
		}
		timer.Reset(2 * time.Second)
	}
}

func (scheduler *Scheduler) observe(ctx context.Context) error {
	previous, err := scheduler.Store.List(ctx, scheduler.Name)
	if err != nil {
		return err
	}

	observed, err := scheduler.Service.Observe(ctx, previous)
	if err != nil {
		return err
	}
	for _, job := range observed.Jobs {
		job.Service = scheduler.Name
		job.UpdatedAt = scheduler.Now().UTC()
		if _, err := scheduler.Store.Observe(ctx, job); err != nil {
			return err
		}
	}
	if err := scheduler.requestCompletedRemovals(ctx, observed.Complete); err != nil {
		return err
	}

	// Only a successful complete queue read can prove that an item vanished.
	return scheduler.Store.ReconcileQueue(ctx, scheduler.Name, observed.Queue, scheduler.Now())
}

func (scheduler *Scheduler) advance(ctx context.Context) error {
	listed, err := scheduler.Store.List(ctx, scheduler.Name)
	if err != nil {
		return err
	}
	disabled, err := scheduler.Disabled()
	if err != nil {
		return err
	}

	engine := Engine{Store: scheduler.Store, Adapter: scheduler.Service, Now: scheduler.Now}
	var failures []error
	for _, job := range listed {
		if err := ctx.Err(); err != nil {
			return err
		}

		if err := scheduler.advanceJob(ctx, engine, job, disabled); err != nil && !errors.Is(err, jobs.ErrConflict) {
			failures = append(failures, fmt.Errorf("job %d: %w", job.ID, err))
		}
	}

	return errors.Join(failures...)
}

func (scheduler *Scheduler) advanceJob(ctx context.Context, engine Engine, job jobs.Job, disabled bool) error {
	if job.State == jobs.Importing || job.State == jobs.Running {
		return engine.Run(ctx, job.ID)
	}
	if scheduler.Now().Before(job.RetryAt) {
		return nil
	}

	if job.PendingAction == jobs.Delete {
		return nil
	}
	if job.State == jobs.Observed && job.CollectionError == "" && len(job.Evidence) != 0 {
		return scheduler.plan(ctx, job)
	}
	if job.State == jobs.Ready && job.CollectionError == "" && !disabled && scheduler.Service.Ready(job) {
		return engine.Run(ctx, job.ID)
	}

	return nil
}

func (scheduler *Scheduler) requestCompletedRemovals(ctx context.Context, complete []jobs.QueueKey) error {
	disabled, err := scheduler.Disabled()
	if err != nil || disabled || len(complete) == 0 {
		return err
	}
	listed, err := scheduler.Store.List(ctx, scheduler.Name)
	if err != nil {
		return err
	}
	eligible := make(map[jobs.QueueKey]bool, len(complete))
	for _, key := range complete {
		eligible[key] = true
	}

	for _, job := range listed {
		if !eligible[jobs.QueueKey{QueueID: job.QueueID, DownloadID: job.DownloadID}] ||
			job.PendingAction != "" || job.State == jobs.Removed {
			continue
		}
		// Automatic cleanup shares the durable action path with UI removal.
		// An active repair wins the transaction and cannot be removed here.
		err := scheduler.Store.RequestAction(ctx, job.ID, jobs.Delete, "", 0, scheduler.Now())
		if err != nil && !errors.Is(err, jobs.ErrConflict) {
			return err
		}
	}
	return nil
}

// Operator queue actions must not wait behind a model response or a long media
// command. Database state excludes removal and repair of the same job.
func (scheduler *Scheduler) runActions(ctx context.Context, workWake chan<- struct{}) {
	timer := time.NewTicker(2 * time.Second)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-scheduler.Wake:
			select {
			case workWake <- struct{}{}:
			default:
			}
		case <-timer.C:
		}

		if err := scheduler.removeRequested(ctx); err != nil && ctx.Err() == nil {
			scheduler.Log.Error("remove queue tracking", "service", scheduler.Name, "error", err)
		}
	}
}

func (scheduler *Scheduler) removeRequested(ctx context.Context) error {
	listed, err := scheduler.Store.List(ctx, scheduler.Name)
	if err != nil {
		return err
	}

	var failures []error
	for _, job := range listed {
		if job.PendingAction != jobs.Delete || scheduler.Now().Before(job.RetryAt) {
			continue
		}

		requested, err := scheduler.Store.StartRemoval(ctx, job.ID, scheduler.Now())
		if errors.Is(err, jobs.ErrConflict) {
			continue
		}
		if err != nil {
			return err
		}

		removeErr := scheduler.Service.Remove(ctx, requested)
		storeErr := scheduler.Store.FinishRemoval(context.WithoutCancel(ctx), requested, removeErr, scheduler.Now())
		if err := errors.Join(removeErr, storeErr); err != nil {
			failures = append(failures, fmt.Errorf("job %d: %w", job.ID, err))
		}
	}

	return errors.Join(failures...)
}

func (scheduler *Scheduler) plan(ctx context.Context, job jobs.Job) error {
	decision, err := scheduler.Service.Plan(ctx, job)
	job.PlanningAttempts++
	job.UpdatedAt = scheduler.Now().UTC()
	if err != nil {
		job.Reason = fmt.Sprintf("planning: %v", err)
		job.RetryAt = job.UpdatedAt.Add(planningDelay(job.PlanningAttempts))
	} else {
		job.Plan = decision.Data
		job.Reason = decision.Reason
		job.State = jobs.Blocked
		if decision.Repair {
			job.State = jobs.Ready
		}
	}

	return errors.Join(err, scheduler.Store.FinishPlanning(ctx, job))
}

func planningDelay(attempt int) time.Duration {
	delay := 5 * time.Minute
	for count := 1; count < attempt && delay < 6*time.Hour; count++ {
		delay *= 2
	}

	return min(delay, 6*time.Hour)
}
