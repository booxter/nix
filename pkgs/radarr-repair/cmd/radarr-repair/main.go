package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/booxter/nix-config/radarr-repair/contracts"
)

const maximumDocumentSize = 8 << 20

type application struct {
	inspect inspectFunc
}

func newApplication() application {
	return application{inspect: inspectCase}
}

func run(arguments []string, stdin io.Reader, stdout, stderr io.Writer) error {
	return newApplication().run(context.Background(), arguments, stdin, stdout, stderr)
}

func (app application) run(
	ctx context.Context,
	arguments []string,
	stdin io.Reader,
	stdout, stderr io.Writer,
) error {
	if len(arguments) == 0 {
		writeUsage(stderr)
		return fmt.Errorf("expected inspect, validate-case, or validate-decision")
	}

	switch arguments[0] {
	case "inspect":
		return app.runInspect(ctx, arguments[1:], stdout, stderr)
	case "validate-case":
		data, err := readCommandDocument("validate-case", arguments[1:], stdin, stderr)
		if err != nil {
			return err
		}
		if _, err := contracts.DecodeCase(data); err != nil {
			return err
		}
		_, err = fmt.Fprintln(stdout, "valid repair case")
		return err
	case "validate-decision":
		data, err := readCommandDocument("validate-decision", arguments[1:], stdin, stderr)
		if err != nil {
			return err
		}
		decision, err := contracts.DecodeDecision(data)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(stdout, "valid repair decision: %s\n", decision.Kind)
		return err
	default:
		writeUsage(stderr)
		return fmt.Errorf("unknown command %q", arguments[0])
	}
}

func readCommandDocument(
	command string,
	arguments []string,
	stdin io.Reader,
	stderr io.Writer,
) ([]byte, error) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintf(stderr, "usage: radarr-repair %s FILE\n", command)
	}
	if err := flags.Parse(arguments); err != nil {
		return nil, err
	}
	if flags.NArg() != 1 {
		flags.Usage()
		return nil, fmt.Errorf("%s expects exactly one file", command)
	}
	return readDocument(flags.Arg(0), stdin)
}

func readDocument(path string, stdin io.Reader) ([]byte, error) {
	if path == "-" {
		return readBounded(stdin)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()
	data, err := readBounded(file)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return data, nil
}

func readBounded(reader io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, maximumDocumentSize+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maximumDocumentSize {
		return nil, fmt.Errorf("JSON document exceeds %d bytes", maximumDocumentSize)
	}
	return data, nil
}

func writeUsage(writer io.Writer) {
	_, _ = fmt.Fprintln(writer, "usage: radarr-repair <inspect|validate-case|validate-decision> ...")
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := newApplication().run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
