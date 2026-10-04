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
	flags.DurationVar(&config.probeTimeout, "timeout", 30*time.Second, "probe timeout")
	flags.DurationVar(&config.mediaTimeout, "media-timeout", 30*time.Minute, "media operation timeout")

	roots := mediaroot.NewMappings()
	flags.Var(roots, "root", "media root as ID=PATH; repeatable")
	if err := flags.Parse(args); err != nil {
		return config, err
	}
	if flags.NArg() != 0 || config.operation == "" {
		return config, fmt.Errorf("--operation is required; no positional arguments accepted")
	}

	config.roots = roots.Paths()
	return config, nil
}
