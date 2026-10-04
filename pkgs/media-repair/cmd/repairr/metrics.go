package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/prometheus/client_golang/prometheus"
)

func reportMetrics(ctx context.Context, path string, store *jobs.Store, schedulers map[jobs.Service]*repair.Scheduler) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		if err := writeMetrics(ctx, path, store, schedulers); err != nil && ctx.Err() == nil {
			slog.Error("write Repairr metrics", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func writeMetrics(ctx context.Context, path string, store *jobs.Store, schedulers map[jobs.Service]*repair.Scheduler) error {
	registry := prometheus.NewRegistry()
	observed := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "repairr_queue_observed_timestamp_seconds",
		Help: "Last successful complete queue observation.",
	}, []string{"service"})
	counts := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "repairr_jobs",
		Help: "Current jobs by service and state.",
	}, []string{"service", "state"})
	disabled := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "repairr_repairs_disabled",
		Help: "Whether automatic repairs are disabled by the operator.",
	}, []string{"service"})
	registry.MustRegister(observed, counts, disabled)

	for service, scheduler := range schedulers {
		label := string(service)
		observed.WithLabelValues(label).Set(float64(scheduler.LastObservation.Load()))
		stopped, err := scheduler.Disabled()
		if err != nil {
			return err
		}
		disabled.WithLabelValues(label).Set(0)
		if stopped {
			disabled.WithLabelValues(label).Set(1)
		}
		for _, state := range []jobs.State{jobs.Observed, jobs.Ready, jobs.Running, jobs.Importing, jobs.Blocked, jobs.Failed, jobs.Removing} {
			counts.WithLabelValues(label, string(state)).Set(0)
		}
		listed, err := store.List(ctx, service)
		if err != nil {
			return err
		}
		for _, job := range listed {
			if job.InQueue || job.State == jobs.Importing {
				counts.WithLabelValues(label, string(job.State)).Inc()
			}
		}
	}

	return prometheus.WriteToTextfile(path, registry)
}
