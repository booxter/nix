package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/booxter/nix-config/seerr-reconcile/internal/reconcile"
)

func run() error {
	configPath := flag.String("config", "", "path to declarative reconciliation configuration")
	seerrURL := flag.String("url", "http://127.0.0.1:5055", "Seerr base URL")
	apiKeyCredential := flag.String("api-key-credential", "seerr-api-key", "systemd credential containing the Seerr API key")
	timeout := flag.Duration("timeout", 30*time.Second, "HTTP and reconciliation timeout")
	flag.Parse()
	if *configPath == "" {
		return fmt.Errorf("--config is required")
	}
	credentialDirectory := os.Getenv("CREDENTIALS_DIRECTORY")
	if credentialDirectory == "" {
		return fmt.Errorf("CREDENTIALS_DIRECTORY is not set")
	}
	credentials := reconcile.SystemdCredentials{Directory: credentialDirectory}
	apiKey, err := credentials.ReadRaw(*apiKeyCredential)
	if err != nil {
		return err
	}
	config, err := reconcile.ReadConfig(*configPath)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: *timeout}
	api, err := reconcile.NewHTTPAPI(*seerrURL, apiKey, client)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	result, err := reconcile.Run(ctx, api, credentials, config)
	if err != nil {
		return err
	}
	if len(result.Changed) == 0 {
		fmt.Println("Seerr settings already match declarative configuration")
		return nil
	}
	fmt.Printf("Reconciled Seerr: %v\n", result.Changed)
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "seerr-reconcile: %v\n", err)
		os.Exit(1)
	}
}
