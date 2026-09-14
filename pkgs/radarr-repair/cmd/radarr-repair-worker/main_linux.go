package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/booxter/nix-config/radarr-repair/internal/ffprobe"
	"github.com/booxter/nix-config/radarr-repair/internal/mediaroot"
	"github.com/booxter/nix-config/radarr-repair/worker/joinfinish"
	"github.com/booxter/nix-config/radarr-repair/worker/joininspect"
	"github.com/booxter/nix-config/radarr-repair/worker/joinrequest"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstage"
	"github.com/booxter/nix-config/radarr-repair/worker/joinstate"
	"github.com/booxter/nix-config/radarr-repair/worker/mediafile"
	"github.com/booxter/nix-config/radarr-repair/worker/mediajoin"
	workerprobe "github.com/booxter/nix-config/radarr-repair/worker/probe"
	workerserver "github.com/booxter/nix-config/radarr-repair/worker/server"
)

const (
	defaultProbeTimeout  = 30 * time.Second
	defaultJoinTimeout   = 30 * time.Minute
	defaultMaxConcurrent = 2
	shutdownTimeout      = 5 * time.Second
	writeTimeoutMargin   = 5 * time.Second
)

func run(ctx context.Context, arguments []string, stderr io.Writer) error {
	flags := flag.NewFlagSet("radarr-repair-worker", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: radarr-repair-worker --socket PATH --state-directory PATH "+
				"--root ID=PATH [--root ID=PATH ...]",
		)
	}
	socketPath := flags.String("socket", "", "Unix socket path")
	stateDirectory := flags.String("state-directory", "", "private state directory")
	ffprobePath := flags.String("ffprobe", "", "absolute ffprobe executable path")
	ffmpegPath := flags.String("ffmpeg", "", "absolute ffmpeg executable path")
	probeTimeout := flags.Duration("timeout", defaultProbeTimeout, "maximum probe duration")
	joinTimeout := flags.Duration(
		"join-timeout",
		defaultJoinTimeout,
		"maximum staged join request duration",
	)
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
	if *stateDirectory == "" {
		return fmt.Errorf("worker state directory is required")
	}
	if *ffprobePath == "" {
		return fmt.Errorf("ffprobe executable is required")
	}
	if *ffmpegPath == "" {
		return fmt.Errorf("ffmpeg executable is required")
	}
	if *probeTimeout <= 0 {
		return fmt.Errorf("probe timeout must be positive")
	}
	if *joinTimeout <= 0 {
		return fmt.Errorf("join timeout must be positive")
	}
	requestTimeout := max(*probeTimeout, *joinTimeout)
	if requestTimeout > time.Duration(math.MaxInt64)-writeTimeoutMargin {
		return fmt.Errorf("worker request timeout is too large")
	}
	writeTimeout := requestTimeout + writeTimeoutMargin
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
	probeExecutor, err := workerprobe.NewExecutor(rootSet, probeRunner)
	if err != nil {
		return err
	}
	probeHandler, err := workerserver.NewHandler(
		probeExecutor,
		*probeTimeout,
		*maxConcurrent,
	)
	if err != nil {
		return err
	}
	state, err := joinstate.New(*stateDirectory)
	if err != nil {
		return err
	}
	joinRunner, err := mediajoin.NewRunner(*ffmpegPath, *joinTimeout)
	if err != nil {
		return err
	}
	joinStager, err := joinstage.NewExecutor(rootSet, rootSet, joinRunner, probeRunner)
	if err != nil {
		return err
	}
	joinExecutor, err := joinrequest.NewExecutor(joinrequest.Dependencies{
		Store: state, Stager: joinStager, Clock: wallClock{},
	})
	if err != nil {
		return err
	}
	stageJoinHandler, err := workerserver.NewStageJoinHandler(joinExecutor, *joinTimeout)
	if err != nil {
		return err
	}
	finishExecutor, err := joinfinish.NewExecutor(joinfinish.Dependencies{
		Store: state, Artifacts: rootSet, Clock: wallClock{},
	})
	if err != nil {
		return err
	}
	publishHandler, err := workerserver.NewPublishHandler(finishExecutor, *joinTimeout)
	if err != nil {
		return err
	}
	discardHandler, err := workerserver.NewDiscardHandler(finishExecutor, *joinTimeout)
	if err != nil {
		return err
	}
	inspectExecutor, err := joininspect.NewExecutor(state)
	if err != nil {
		return err
	}
	inspectHandler, err := workerserver.NewInspectJoinHandler(inspectExecutor, *probeTimeout)
	if err != nil {
		return err
	}
	router, err := workerserver.NewRouter(
		probeHandler,
		stageJoinHandler,
		publishHandler,
		discardHandler,
		inspectHandler,
	)
	if err != nil {
		return err
	}
	listener, err := workerserver.ListenUnix(*socketPath)
	if err != nil {
		return err
	}

	server := &http.Server{
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      writeTimeout,
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

type wallClock struct{}

func (wallClock) Now() time.Time {
	return time.Now()
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
