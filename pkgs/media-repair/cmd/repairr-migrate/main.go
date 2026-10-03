package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
	"github.com/booxter/nix-config/media-repair/internal/mediaroot"
	"github.com/booxter/nix-config/media-repair/internal/statemigration"
)

func main() {
	source := flag.String("source", "", "read-only copy of the old /var/lib repair state")
	database := flag.String("database", "", "new SQLite database path")
	roots := mediaroot.NewMappings()
	flag.Var(roots, "root", "configured media root as ID=PATH; repeatable")
	flag.Parse()
	if err := convert(*source, *database, roots.Paths()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func convert(source, database string, roots map[string]string) error {
	if source == "" || database == "" {
		return fmt.Errorf("source and database paths are required")
	}
	batch, err := statemigration.Convert(source, roots)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(database), ".repairr-conversion-*.db")
	if err != nil {
		return err
	}
	path := temporary.Name()
	defer os.Remove(path)
	if err := temporary.Close(); err != nil {
		return err
	}
	store, err := jobs.Open(path)
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.Import(context.Background(), batch); err != nil {
		return err
	}
	// Close checkpoints SQLite's WAL. Publish only the complete database, and
	// never replace an existing destination on a repeated activation.
	if err := store.Close(); err != nil {
		return err
	}
	if err := os.Link(path, database); err != nil {
		return err
	}
	attempts := 0
	imported := 0
	for _, entry := range batch {
		attempts += len(entry.Attempts)
		for _, attempt := range entry.Attempts {
			if attempt.State == jobs.Imported {
				imported++
			}
		}
	}
	fmt.Printf("converted %d jobs, %d attempts, %d confirmed imports\n", len(batch), attempts, imported)
	return nil
}
