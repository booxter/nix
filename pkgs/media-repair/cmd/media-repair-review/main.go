package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type config struct {
	Listen         string
	LidarrSnapshot string
	RadarrSnapshot string
	LidarrURL      string
	RadarrURL      string
}

func parseConfig(arguments []string, stderr io.Writer) (config, error) {
	flags := flag.NewFlagSet("media-repair-review", flag.ContinueOnError)
	flags.SetOutput(stderr)
	listen := flags.String("listen", "127.0.0.1:8790", "loopback HTTP listen address")
	lidarrSnapshot := flags.String("lidarr-snapshot", "", "Lidarr review spool directory")
	radarrSnapshot := flags.String("radarr-snapshot", "", "Radarr review spool directory")
	lidarrURL := flags.String("lidarr-url", "", "browser-facing Lidarr queue URL")
	radarrURL := flags.String("radarr-url", "", "browser-facing Radarr queue URL")
	if err := flags.Parse(arguments); err != nil {
		return config{}, err
	}
	if flags.NArg() != 0 {
		return config{}, fmt.Errorf("unexpected positional arguments")
	}
	configuration := config{
		Listen: *listen, LidarrSnapshot: *lidarrSnapshot, RadarrSnapshot: *radarrSnapshot,
		LidarrURL: *lidarrURL, RadarrURL: *radarrURL,
	}
	if err := validateConfig(configuration); err != nil {
		return config{}, err
	}
	return configuration, nil
}

func validateConfig(configuration config) error {
	host, _, err := net.SplitHostPort(configuration.Listen)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("listen address must use a loopback IP")
	}
	for name, path := range map[string]string{
		"Lidarr snapshot": configuration.LidarrSnapshot,
		"Radarr snapshot": configuration.RadarrSnapshot,
	} {
		if path == "" || !filepath.IsAbs(path) || filepath.Clean(path) != path ||
			filepath.Dir(path) == path {
			return fmt.Errorf("%s directory must be a clean absolute path", name)
		}
	}
	for name, raw := range map[string]string{
		"Lidarr": configuration.LidarrURL,
		"Radarr": configuration.RadarrURL,
	} {
		parsed, err := url.Parse(raw)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil ||
			parsed.RawQuery != "" || parsed.Fragment != "" {
			return fmt.Errorf("%s URL must be an absolute HTTPS URL without credentials", name)
		}
	}
	return nil
}

func run(ctx context.Context, arguments []string, stderr io.Writer) error {
	configuration, err := parseConfig(arguments, stderr)
	if err != nil {
		return err
	}
	handler, err := newHandler(configuration)
	if err != nil {
		return err
	}
	server := &http.Server{
		Addr: configuration.Listen, Handler: handler,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second,
	}
	listener, err := net.Listen("tcp", configuration.Listen)
	if err != nil {
		return fmt.Errorf("listen for repair review: %w", err)
	}
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()
	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return errors.Join(server.Shutdown(shutdownContext), ctx.Err())
	}
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stderr); err != nil && !errors.Is(err, context.Canceled) {
		if !errors.Is(err, flag.ErrHelp) {
			_, _ = fmt.Fprintln(os.Stderr, strings.TrimSpace(err.Error()))
			os.Exit(1)
		}
	}
}
