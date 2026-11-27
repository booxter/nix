package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
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
	"github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/repair"
	"github.com/booxter/nix-config/media-repair/internal/repairui"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"github.com/booxter/nix-config/media-repair/internal/telemetry"
	"github.com/booxter/nix-config/media-repair/internal/workerclient"
	"go.opentelemetry.io/otel"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	path := flag.String("config", "", "Repairr JSON configuration file")
	scanOnce := flag.Bool("collect-radarr", false, "scan the Radarr queue once and write one JSON report per entry")
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	configuration, err := readConfig(*path)
	if err == nil {
		err = run(ctx, configuration, *scanOnce)
	}
	if err != nil {
		slog.Error("Repairr stopped", "error", err)
		os.Exit(1)
	}
}

// run starts the selected mode. Only the long-running daemon needs the planner and job database.
func run(ctx context.Context, configuration config, scanOnce bool) error {
	if configuration.TraceEndpoint != "" {
		provider, err := telemetry.NewProvider(ctx, "repairr", configuration.TraceEndpoint)
		if err != nil {
			slog.Warn("initialize tracing", "error", err)
		} else {
			otel.SetTracerProvider(provider)
			defer telemetry.Shutdown(provider)
		}
	}

	transport, err := servarr.DirectHTTPTransport()
	if err != nil {
		return err
	}
	defer transport.CloseIdleConnections()
	limits := configuration.Timeouts
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   time.Duration(limits.RequestSeconds) * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	media, err := workerclient.NewProcess(configuration.Helper, configuration.Roots,
		time.Duration(limits.ProbeSeconds)*time.Second,
		time.Duration(limits.MediaSeconds)*time.Second,
		time.Duration(limits.ResponseGraceSeconds)*time.Second, configuration.TraceEndpoint)
	if err != nil {
		return err
	}

	radarrClient, inspector, err := configuration.radarrInspection(httpClient, media)
	if err != nil {
		return err
	}
	if scanOnce {
		return writeRadarrQueueReport(ctx, radarrClient, inspector, os.Stdout)
	}

	planner, err := plannerclient.New(configuration.PlannerSocket,
		time.Duration(limits.PlanningSeconds+limits.ResponseGraceSeconds)*time.Second)
	if err != nil {
		return err
	}
	defer planner.Close()
	services, err := configuration.newRepairServices(httpClient, radarrClient, inspector, planner, media)
	if err != nil {
		return err
	}
	store, err := jobs.Open(configuration.Database, services.planningInputs)
	if err != nil {
		return err
	}
	defer store.Close()

	return serve(ctx, configuration, store, services)
}

type repairServices map[jobs.Service]repair.Service

func (services repairServices) planningInputs(service jobs.Service, evidence json.RawMessage) (planning.Inputs, error) {
	adapter, found := services[service]
	if !found {
		return planning.Inputs{}, fmt.Errorf("repair service %q is not configured", service)
	}
	return adapter.PlanningInputs(evidence)
}

// serve runs the repair workers and their web UI together and waits for them to shut down.
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

// repairsDisabled allows repairs only when the disable file is known to be absent.
func repairsDisabled(path string) (bool, error) {
	_, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return true, err
}
