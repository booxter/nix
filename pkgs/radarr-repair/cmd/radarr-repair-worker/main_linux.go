package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	"github.com/booxter/nix-config/radarr-repair/internal/mediaroot"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	workerprobe "github.com/booxter/nix-config/radarr-repair/worker/probe"
	workerserver "github.com/booxter/nix-config/radarr-repair/worker/server"
)

const (
	defaultProbeTimeout  = 30 * time.Second
	defaultMaxConcurrent = 2
	shutdownTimeout      = 5 * time.Second
)

func run(ctx context.Context, arguments []string, stderr io.Writer) error {
	flags := flag.NewFlagSet("radarr-repair-worker", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: radarr-repair-worker --socket PATH --root ID=PATH [--root ID=PATH ...]",
		)
	}
	socketPath := flags.String("socket", "", "Unix socket path")
	ffprobePath := flags.String("ffprobe", "", "absolute ffprobe executable path")
	probeTimeout := flags.Duration("timeout", defaultProbeTimeout, "maximum probe duration")
	maxConcurrent := flags.Int(
		"max-concurrent",
		defaultMaxConcurrent,
		"maximum concurrent probes",
	)
	roots := mediaroot.NewMappings()
	flags.Var(roots, "root", "media root as ID=PATH; repeatable")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("unexpected positional arguments")
	}
	if *socketPath == "" {
		return fmt.Errorf("worker socket is required")
	}
	if *ffprobePath == "" {
		return fmt.Errorf("ffprobe executable is required")
	}
	if len(roots) == 0 {
		return fmt.Errorf("at least one media root is required")
	}
	if err := ctx.Err(); err != nil {
		return nil
	}

	rootSet, err := mediafile.NewRootSet(roots.Paths())
	if err != nil {
		return err
	}
	defer rootSet.Close()
	probeRunner, err := ffprobe.NewRunner(*ffprobePath, *probeTimeout)
	if err != nil {
		return err
	}
	executor, err := workerprobe.NewExecutor(rootSet, probeRunner)
	if err != nil {
		return err
	}
	handler, err := workerserver.NewHandler(executor, *probeTimeout, *maxConcurrent)
	if err != nil {
		return err
	}
	listener, err := workerserver.ListenUnix(*socketPath)
	if err != nil {
		return err
	}

	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      *probeTimeout + 5*time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    8 << 10,
		ErrorLog:          log.New(stderr, "", 0),
	}
	serveErrors := make(chan error, 1)
	go func() {
		serveErrors <- server.Serve(listener)
	}()

	select {
	case err := <-serveErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve worker requests: %w", err)
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownContext); err != nil {
			_ = server.Close()
			return fmt.Errorf("shut down worker server: %w", err)
		}
		err := <-serveErrors
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve worker requests: %w", err)
		}
		return nil
	}
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stderr); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
