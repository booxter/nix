package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/alecthomas/kong"
	"github.com/booxter/nix-config/seerr-tools/internal/remote"
	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/booxter/nix-config/seerr-tools/internal/servarr"
	"github.com/booxter/nix-config/seerr-tools/internal/storage"
)

const (
	defaultSeerrURL     = "http://127.0.0.1:5055"
	defaultSettingsFile = "/data/.state/nixarr/seerr/settings.json"
)

type CLI struct {
	JSON       bool    `help:"Emit machine-readable JSON."`
	SSHHost    string  `default:"srvarr" help:"Host on which to run the report."`
	Local      bool    `help:"Run locally instead of on --ssh-host."`
	SeerrURL   string  `default:"http://127.0.0.1:5055" help:"Seerr base URL."`
	APIKeyFile string  `default:"/data/.state/nixarr/seerr/settings.json" help:"File containing the Seerr API key or settings.json." type:"path"`
	PageSize   int     `default:"100" help:"Requests to fetch per page."`
	Timeout    float64 `default:"30" help:"API timeout in seconds."`
}

func (cli CLI) validate() error {
	if cli.PageSize < 1 {
		return fmt.Errorf("--page-size must be positive")
	}
	if cli.Timeout <= 0 {
		return fmt.Errorf("--timeout must be positive")
	}
	return nil
}

func run(ctx context.Context, cli CLI, originalArguments []string) error {
	if err := cli.validate(); err != nil {
		return err
	}
	if !cli.Local {
		return remote.Run(
			ctx,
			remote.ExecRunner{Stdout: os.Stdout, Stderr: os.Stderr},
			cli.SSHHost,
			"seerr-request-storage",
			originalArguments,
		)
	}
	timeout := time.Duration(cli.Timeout * float64(time.Second))
	apiKey, err := seerr.ReadAPIKey(cli.APIKeyFile)
	if err != nil {
		return err
	}
	client, err := seerr.NewClient(cli.SeerrURL, apiKey, timeout)
	if err != nil {
		return err
	}
	radarrServices, err := client.Services(ctx, seerr.Radarr)
	if err != nil {
		return fmt.Errorf("read Seerr Radarr settings: %w", err)
	}
	sonarrServices, err := client.Services(ctx, seerr.Sonarr)
	if err != nil {
		return fmt.Errorf("read Seerr Sonarr settings: %w", err)
	}
	requests, err := client.Requests(ctx, cli.PageSize)
	if err != nil {
		return fmt.Errorf("read Seerr requests: %w", err)
	}
	report, err := storage.Build(
		ctx,
		requests,
		radarrServices,
		sonarrServices,
		servarr.NewCatalog(timeout),
	)
	if err != nil {
		return err
	}
	if cli.JSON {
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(report)
	}
	storage.Render(os.Stdout, report)
	return nil
}

func main() {
	var cli CLI
	parser := kong.Must(
		&cli,
		kong.Name("seerr-request-storage"),
		kong.Description(
			"Report Radarr and Sonarr storage attributable to Seerr users.",
		),
		kong.UsageOnError(),
	)
	_, err := parser.Parse(os.Args[1:])
	parser.FatalIfErrorf(err)
	if err := run(context.Background(), cli, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
