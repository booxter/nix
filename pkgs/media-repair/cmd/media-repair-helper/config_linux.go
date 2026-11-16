package main

import (
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/booxter/nix-config/media-repair/internal/mediaroot"
)

type configuration struct {
	operation      string
	roots          map[string]string
	ffprobe        string
	ffmpeg         string
	mkvmerge       string
	lsdvd          string
	lsar           string
	unar           string
	cueconvert     string
	cuebreakpoints string
	wvunpack       string
	probeTimeout   time.Duration
	mediaTimeout   time.Duration
	traceEndpoint  string
	traceparent    string
	tracestate     string
}

func parseConfig(args []string, stderr io.Writer) (configuration, error) {
	var config configuration
	flags := flag.NewFlagSet("media-repair-helper", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&config.operation, "operation", "", "media operation")
	flags.StringVar(&config.ffprobe, "ffprobe", "", "ffprobe executable")
	flags.StringVar(&config.ffmpeg, "ffmpeg", "", "ffmpeg executable")
	flags.StringVar(&config.mkvmerge, "mkvmerge", "", "mkvmerge executable")
	flags.StringVar(&config.lsdvd, "lsdvd", "", "lsdvd executable")
	flags.StringVar(&config.lsar, "lsar", "", "lsar executable")
	flags.StringVar(&config.unar, "unar", "", "unar executable")
	flags.StringVar(&config.cueconvert, "cueconvert", "", "cueconvert executable")
	flags.StringVar(&config.cuebreakpoints, "cuebreakpoints", "", "cuebreakpoints executable")
	flags.StringVar(&config.wvunpack, "wvunpack", "", "wvunpack executable")
	flags.DurationVar(&config.probeTimeout, "timeout", 0, "required probe timeout")
	flags.DurationVar(&config.mediaTimeout, "media-timeout", 0, "required media operation timeout")
	flags.StringVar(&config.traceEndpoint, "trace-endpoint", "", "local OTLP Unix socket endpoint")
	flags.StringVar(&config.traceparent, "traceparent", "", "W3C trace parent")
	flags.StringVar(&config.tracestate, "tracestate", "", "W3C trace state")

	roots := mediaroot.NewMappings()
	flags.Var(roots, "root", "media root as ID=PATH; repeatable")
	if err := flags.Parse(args); err != nil {
		return config, err
	}
	if flags.NArg() != 0 || config.operation == "" {
		return config, fmt.Errorf("--operation is required; no positional arguments accepted")
	}
	if config.probeTimeout <= 0 || config.mediaTimeout <= 0 {
		return config, fmt.Errorf("--timeout and --media-timeout must be positive")
	}

	config.roots = roots.Paths()
	return config, nil
}
