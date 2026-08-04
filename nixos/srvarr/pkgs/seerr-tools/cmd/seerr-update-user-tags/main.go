package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/alecthomas/kong"
	"github.com/booxter/nix-config/seerr-tools/internal/remote"
	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/booxter/nix-config/seerr-tools/internal/servarr"
	"github.com/booxter/nix-config/seerr-tools/internal/tagging"
)

type CLI struct {
	Apply      bool    `help:"Create missing tags and update items."`
	SSHHost    string  `default:"srvarr" help:"Host on which to run the updater."`
	Local      bool    `help:"Run locally instead of on --ssh-host."`
	SeerrURL   string  `default:"http://127.0.0.1:5055" help:"Seerr base URL."`
	APIKeyFile string  `default:"/data/.state/nixarr/seerr/settings.json" help:"File containing the Seerr API key or settings.json." type:"path"`
	PageSize   int     `default:"100" help:"Requests to fetch per page."`
	BatchSize  int     `default:"500" help:"Maximum items per Radarr or Sonarr update."`
	Timeout    float64 `default:"30" help:"API timeout in seconds."`
	User       []int   `help:"Only backfill this Seerr user ID; may be repeated."`
	Verbose    bool    `help:"List individual titles."`
}

func (cli CLI) validate() error {
	if cli.PageSize < 1 {
		return fmt.Errorf("--page-size must be positive")
	}
	if cli.BatchSize < 1 {
		return fmt.Errorf("--batch-size must be positive")
	}
	if cli.Timeout <= 0 {
		return fmt.Errorf("--timeout must be positive")
	}
	return nil
}

func (cli CLI) localArguments() []string {
	arguments := []string{
		"--seerr-url", cli.SeerrURL,
		"--api-key-file", cli.APIKeyFile,
		"--page-size", strconv.Itoa(cli.PageSize),
		"--batch-size", strconv.Itoa(cli.BatchSize),
		"--timeout", strconv.FormatFloat(cli.Timeout, 'g', -1, 64),
	}
	if cli.Apply {
		arguments = append(arguments, "--apply")
	}
	if cli.Verbose {
		arguments = append(arguments, "--verbose")
	}
	for _, userID := range cli.User {
		arguments = append(arguments, "--user", strconv.Itoa(userID))
	}
	return arguments
}

func run(ctx context.Context, cli CLI) error {
	if err := cli.validate(); err != nil {
		return err
	}
	if !cli.Local {
		return remote.Run(
			ctx,
			remote.ExecRunner{Stdout: os.Stdout, Stderr: os.Stderr},
			cli.SSHHost,
			"seerr-update-user-tags",
			cli.localArguments(),
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
	_, err = tagging.Update(
		ctx,
		requests,
		radarrServices,
		sonarrServices,
		servarr.NewCatalog(timeout),
		tagging.Options{
			Apply:     cli.Apply,
			Verbose:   cli.Verbose,
			BatchSize: cli.BatchSize,
			UserIDs:   cli.User,
		},
		os.Stdout,
	)
	return err
}

func main() {
	var cli CLI
	parser := kong.Must(
		&cli,
		kong.Name("seerr-update-user-tags"),
		kong.Description(
			"Backfill Seerr requester tags on existing Radarr and Sonarr items. Runs read-only unless --apply is supplied.",
		),
		kong.UsageOnError(),
	)
	_, err := parser.Parse(os.Args[1:])
	parser.FatalIfErrorf(err)
	if err := run(context.Background(), cli); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
