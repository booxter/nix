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
	"path/filepath"
	"syscall"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/mediaroot"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
	"github.com/booxter/nix-config/media-repair/worker/blurayidentify"
	"github.com/booxter/nix-config/media-repair/worker/bluraypublish"
	"github.com/booxter/nix-config/media-repair/worker/blurayrequest"
	"github.com/booxter/nix-config/media-repair/worker/bluraystage"
	"github.com/booxter/nix-config/media-repair/worker/cuesheet"
	"github.com/booxter/nix-config/media-repair/worker/dvdidentify"
	"github.com/booxter/nix-config/media-repair/worker/dvdpublish"
	"github.com/booxter/nix-config/media-repair/worker/dvdremux"
	"github.com/booxter/nix-config/media-repair/worker/dvdrequest"
	"github.com/booxter/nix-config/media-repair/worker/dvdstage"
	"github.com/booxter/nix-config/media-repair/worker/failurelog"
	"github.com/booxter/nix-config/media-repair/worker/joinfinish"
	"github.com/booxter/nix-config/media-repair/worker/joininspect"
	"github.com/booxter/nix-config/media-repair/worker/joinrequest"
	"github.com/booxter/nix-config/media-repair/worker/joinstage"
	"github.com/booxter/nix-config/media-repair/worker/joinstate"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"github.com/booxter/nix-config/media-repair/worker/mediajoin"
	"github.com/booxter/nix-config/media-repair/worker/mediaremux"
	workerprobe "github.com/booxter/nix-config/media-repair/worker/probe"
	workerserver "github.com/booxter/nix-config/media-repair/worker/server"
)

const (
	defaultProbeTimeout  = 30 * time.Second
	defaultJoinTimeout   = 30 * time.Minute
	defaultMaxConcurrent = 2
	shutdownTimeout      = 5 * time.Second
	writeTimeoutMargin   = 5 * time.Second
)

func run(ctx context.Context, arguments []string, stderr io.Writer) error {
	flags := flag.NewFlagSet("media-repair-worker", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: media-repair-worker --socket PATH --state-directory PATH "+
				"--root ID=PATH [--root ID=PATH ...]",
		)
	}
	socketPath := flags.String("socket", "", "Unix socket path")
	stateDirectory := flags.String("state-directory", "", "private state directory")
	ffprobePath := flags.String("ffprobe", "", "absolute ffprobe executable path")
	ffmpegPath := flags.String("ffmpeg", "", "absolute ffmpeg executable path")
	mkvmergePath := flags.String("mkvmerge", "", "absolute mkvmerge executable path")
	lsdvdPath := flags.String("lsdvd", "", "absolute lsdvd executable path")
	lsarPath := flags.String("lsar", "", "absolute lsar executable path")
	unarPath := flags.String("unar", "", "absolute unar executable path")
	cueconvertPath := flags.String("cueconvert", "", "absolute cueconvert executable path")
	cuebreakpointsPath := flags.String(
		"cuebreakpoints", "", "absolute cuebreakpoints executable path",
	)
	wvunpackPath := flags.String("wvunpack", "", "absolute wvunpack executable path")
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
	if *lsarPath == "" || *unarPath == "" {
		return fmt.Errorf("RAR listing and extraction executables are required")
	}
	if !filepath.IsAbs(*mkvmergePath) || filepath.Clean(*mkvmergePath) != *mkvmergePath {
		return fmt.Errorf("mkvmerge executable must be an absolute clean path")
	}
	if !filepath.IsAbs(*lsdvdPath) || filepath.Clean(*lsdvdPath) != *lsdvdPath {
		return fmt.Errorf("lsdvd executable must be an absolute clean path")
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
	failureReporter, err := failurelog.NewWriter(stderr)
	if err != nil {
		return err
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
	rarExtractor, err := materialize.NewRARExtractor(*lsarPath, *unarPath)
	if err != nil {
		return err
	}
	cueHandler, err := cuesheet.NewHandler(
		*cueconvertPath, *cuebreakpointsPath, *ffmpegPath, *wvunpackPath,
	)
	if err != nil {
		return err
	}
	materializeExecutor, err := materialize.NewExecutor(
		rootSet, probeRunner, rarExtractor, cueHandler,
	)
	if err != nil {
		return err
	}
	materializeHandler, err := workerserver.NewMaterializeHandler(
		materializeExecutor, *joinTimeout, 1,
	)
	if err != nil {
		return err
	}
	videoMaterializeHandler, err := workerserver.NewVideoMaterializeHandler(
		materializeExecutor, *joinTimeout, 1,
	)
	if err != nil {
		return err
	}
	rarMaterializeHandler, err := workerserver.NewRARMaterializeHandler(
		materializeExecutor, *joinTimeout, 1,
	)
	if err != nil {
		return err
	}
	rarVideoMaterializeHandler, err := workerserver.NewRARVideoMaterializeHandler(
		materializeExecutor, *joinTimeout, 1,
	)
	if err != nil {
		return err
	}
	directoryMaterializeHandler, err := workerserver.NewDirectoryMaterializeHandler(
		materializeExecutor, *joinTimeout, 1,
	)
	if err != nil {
		return err
	}
	dvdExecutor, err := dvdidentify.NewExecutor(rootSet, dvdvideo.Runner{Executable: *lsdvdPath})
	if err != nil {
		return err
	}
	dvdHandler, err := workerserver.NewDVDIdentifyHandler(dvdExecutor, *probeTimeout, *maxConcurrent)
	if err != nil {
		return err
	}
	dvdRemuxRunner, err := dvdremux.NewRunner(*ffmpegPath, *joinTimeout)
	if err != nil {
		return err
	}
	dvdStager, err := dvdstage.NewExecutor(rootSet, rootSet,
		dvdvideo.Runner{Executable: *lsdvdPath}, dvdRemuxRunner, probeRunner)
	if err != nil {
		return err
	}
	dvdRequest, err := dvdrequest.NewExecutor(dvdStager, failureReporter)
	if err != nil {
		return err
	}
	dvdRemuxHandler, err := workerserver.NewDVDRemuxHandler(dvdRequest, *joinTimeout)
	if err != nil {
		return err
	}
	dvdPublisher, err := dvdpublish.NewExecutor(rootSet)
	if err != nil {
		return err
	}
	dvdPublishHandler, err := workerserver.NewDVDPublishHandler(dvdPublisher, *joinTimeout)
	if err != nil {
		return err
	}
	blurayExecutor, err := blurayidentify.NewExecutor(
		rootSet, mkvmerge.Runner{Executable: *mkvmergePath},
	)
	if err != nil {
		return err
	}
	blurayHandler, err := workerserver.NewBlurayIdentifyHandler(
		blurayExecutor, *probeTimeout, *maxConcurrent,
	)
	if err != nil {
		return err
	}
	remuxRunner, err := mediaremux.NewRunner(*mkvmergePath, *joinTimeout)
	if err != nil {
		return err
	}
	blurayStager, err := bluraystage.NewExecutor(
		rootSet, rootSet, mkvmerge.Runner{Executable: *mkvmergePath},
		remuxRunner, probeRunner,
	)
	if err != nil {
		return err
	}
	blurayRequest, err := blurayrequest.NewExecutor(blurayStager, failureReporter)
	if err != nil {
		return err
	}
	blurayRemuxHandler, err := workerserver.NewBlurayRemuxHandler(
		blurayRequest, *joinTimeout,
	)
	if err != nil {
		return err
	}
	blurayPublisher, err := bluraypublish.NewExecutor(rootSet)
	if err != nil {
		return err
	}
	blurayPublishHandler, err := workerserver.NewBlurayPublishHandler(
		blurayPublisher, *joinTimeout,
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
		materializeHandler,
		videoMaterializeHandler,
		rarMaterializeHandler,
		rarVideoMaterializeHandler,
		directoryMaterializeHandler,
		dvdHandler,
		dvdRemuxHandler,
		dvdPublishHandler,
		blurayHandler,
		blurayRemuxHandler,
		blurayPublishHandler,
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
