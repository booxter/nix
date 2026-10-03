package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/booxter/nix-config/media-repair/internal/dvdvideo"
	"github.com/booxter/nix-config/media-repair/internal/ffprobe"
	"github.com/booxter/nix-config/media-repair/internal/mediaoperation"
	"github.com/booxter/nix-config/media-repair/internal/mkvmerge"
	"github.com/booxter/nix-config/media-repair/worker/blurayidentify"
	workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"
	"github.com/booxter/nix-config/media-repair/worker/cuesheet"
	"github.com/booxter/nix-config/media-repair/worker/dvdidentify"
	"github.com/booxter/nix-config/media-repair/worker/materialize"
	"github.com/booxter/nix-config/media-repair/worker/mediafile"
	"github.com/booxter/nix-config/media-repair/worker/operation"
	workerprobe "github.com/booxter/nix-config/media-repair/worker/probe"
)

func run(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	config, err := parseConfig(args, stderr)
	if err != nil {
		return err
	}

	data, err := io.ReadAll(io.LimitReader(stdin, (8<<20)+1))
	if err != nil {
		return err
	}
	if len(data) > 8<<20 {
		return fmt.Errorf("media request exceeds 8 MiB")
	}

	files, err := mediafile.NewRootSet(config.roots)
	if err != nil {
		return err
	}
	defer files.Close()

	prober, err := ffprobe.NewRunner(config.ffprobe, config.probeTimeout)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, config.mediaTimeout)
	defer cancel()

	return config.execute(ctx, data, stdout, files, prober)
}

func (config configuration) execute(
	ctx context.Context,
	data []byte,
	stdout io.Writer,
	files *mediafile.RootSet,
	prober *ffprobe.Runner,
) error {
	switch config.operation {
	case "transform":
		var request mediaoperation.Transform
		if err := json.Unmarshal(data, &request); err != nil {
			return err
		}

		worker := operation.Transformer{
			Roots: config.roots, Files: files, Prober: prober,
			FFmpeg: config.ffmpeg, MKVmerge: config.mkvmerge, LSDVD: config.lsdvd,
			Timeout: config.mediaTimeout,
		}
		output, err := worker.Transform(ctx, request)
		if err != nil {
			return err
		}

		return json.NewEncoder(stdout).Encode(output)

	case "/v1/probe":
		executor, err := workerprobe.NewExecutor(files, prober)
		if err != nil {
			return err
		}

		return invoke(ctx, data, stdout,
			workercontracts.DecodeProbeRequest, executor.Execute, workercontracts.EncodeProbeResponse)

	case "/v1/bluray/identify":
		executor, err := blurayidentify.NewExecutor(files, mkvmerge.Runner{Executable: config.mkvmerge})
		if err != nil {
			return err
		}

		return invoke(ctx, data, stdout,
			workercontracts.DecodeBlurayIdentifyRequest, executor.Execute, workercontracts.EncodeBlurayIdentifyResponse)

	case "/v1/dvd/identify":
		executor, err := dvdidentify.NewExecutor(files, dvdvideo.Runner{Executable: config.lsdvd})
		if err != nil {
			return err
		}

		return invoke(ctx, data, stdout,
			workercontracts.DecodeDVDIdentifyRequest, executor.Execute, workercontracts.EncodeDVDIdentifyResponse)

	case "/v1/materialize/tar-audio", "/v1/materialize/tar-video",
		"/v1/materialize/rar-audio", "/v1/materialize/rar-video", "/v1/materialize/directory-audio":
		return config.materialize(ctx, data, stdout, files, prober)

	default:
		return fmt.Errorf("unknown media operation %q", config.operation)
	}
}

func (config configuration) materialize(
	ctx context.Context,
	data []byte,
	stdout io.Writer,
	files *mediafile.RootSet,
	prober *ffprobe.Runner,
) error {
	rar, err := materialize.NewRARExtractor(config.lsar, config.unar)
	if err != nil {
		return err
	}
	cue, err := cuesheet.NewHandler(config.cueconvert, config.cuebreakpoints, config.ffmpeg, config.wvunpack)
	if err != nil {
		return err
	}
	executor, err := materialize.NewExecutor(files, prober, rar, cue)
	if err != nil {
		return err
	}

	execute := executor.Execute
	switch config.operation {
	case "/v1/materialize/rar-audio", "/v1/materialize/rar-video":
		execute = executor.ExecuteRAR
	case "/v1/materialize/directory-audio":
		execute = executor.ExecuteDirectory
	}

	return invoke(ctx, data, stdout, materialize.DecodeRequest, execute, materialize.EncodeResponse)
}

func invoke[Request, Response any](
	ctx context.Context,
	data []byte,
	output io.Writer,
	decode func([]byte) (Request, error),
	execute func(context.Context, Request) Response,
	encode func(Response) ([]byte, error),
) error {
	request, err := decode(data)
	if err != nil {
		return err
	}

	response, err := encode(execute(ctx, request))
	if err != nil {
		return err
	}

	_, err = output.Write(response)
	return err
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr); err != nil && !errors.Is(err, flag.ErrHelp) {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
