package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/plannerclient"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/internal/repairui"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"github.com/booxter/nix-config/media-repair/internal/workerclient"
)

func main() {
	path := flag.String("config", "", "Repairr JSON configuration file")
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	configuration, err := readConfig(*path)
	if err == nil {
		err = run(ctx, configuration)
	}
	if err != nil {
		slog.Error("Repairr stopped", "error", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, configuration config) error {
	store, err := jobs.Open(configuration.Database)
	if err != nil {
		return err
	}
	defer store.Close()

	transport, err := servarr.DirectHTTPTransport()
	if err != nil {
		return err
	}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   requestTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	planner, err := plannerclient.New(configuration.PlannerSocket, plannerTimeout)
	if err != nil {
		return err
	}
	defer planner.Close()
	media, err := workerclient.NewProcess(configuration.Helper, configuration.Roots, requestTimeout, mediaTimeout)
	if err != nil {
		return err
	}
	defer media.Close()

	radarr, lidarr, err := configuration.services(httpClient, planner, media)
	if err != nil {
		return err
	}
	return serve(ctx, configuration, store, map[jobs.Service]repair.Service{
		jobs.Radarr: radarr,
		jobs.Lidarr: lidarr,
	})
}

func serve(ctx context.Context, configuration config, store *jobs.Store, services map[jobs.Service]repair.Service) error {
	wakes := map[jobs.Service]chan struct{}{
		jobs.Radarr: make(chan struct{}, 1),
		jobs.Lidarr: make(chan struct{}, 1),
	}
	handler, err := repairui.New(repairui.Config{
		Store:   store,
		Origins: configuration.Origins,
		QueueURLs: map[jobs.Service]string{
			jobs.Radarr: configuration.Radarr.QueueURL,
			jobs.Lidarr: configuration.Lidarr.QueueURL,
		},
		Wake: func(service jobs.Service) {
			select {
			case wakes[service] <- struct{}{}:
			default:
			}
		},
	})
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", configuration.Listen)
	if err != nil {
		return err
	}
	defer listener.Close()

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var workers sync.WaitGroup
	schedulers := make(map[jobs.Service]*repair.Scheduler, len(services))
	for name, service := range services {
		settings := configuration.Radarr
		if name == jobs.Lidarr {
			settings = configuration.Lidarr
		}
		scheduler := &repair.Scheduler{
			Store:    store,
			Service:  service,
			Name:     name,
			Now:      wallClock{}.Now,
			Interval: queueInterval,
			Wake:     wakes[name],
			Disabled: func() (bool, error) {
				return repairsDisabled(settings.DisableFile)
			},
			Log: slog.Default(),
		}
		schedulers[name] = scheduler
		workers.Go(func() { scheduler.Run(ctx) })
	}
	workers.Go(func() { reportMetrics(ctx, configuration.MetricsFile, store, schedulers) })

	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       time.Minute,
	}
	workers.Go(func() {
		<-ctx.Done()
		shutdown, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if err := server.Shutdown(shutdown); err != nil {
			slog.Error("stop Repairr HTTP server", "error", err)
		}
	})

	err = server.Serve(listener)
	cancel()
	workers.Wait()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func repairsDisabled(path string) (bool, error) {
	_, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return true, err
}
