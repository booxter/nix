use std::cmp::Ordering;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};
use serde::Deserialize;
use tempfile::{Builder, NamedTempFile};

const FFMPEG: &str = env!("JOIN_MEDIA_PARTS_FFMPEG");
const FFPROBE: &str = env!("JOIN_MEDIA_PARTS_FFPROBE");

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum MediaExtension {
    Ts,
    Mp4,
    Mkv,
}

impl MediaExtension {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ts => "ts",
            Self::Mp4 => "mp4",
            Self::Mkv => "mkv",
        }
    }

    fn default_output(self) -> Self {
        match self {
            Self::Ts | Self::Mkv => Self::Mkv,
            Self::Mp4 => Self::Mp4,
        }
    }
}

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Join ordered TS/MP4/MKV media parts into one file",
    after_help = "Input parts are ordered using natural version ordering.\n\
                  TS output is concatenated directly; MKV and MP4 output is remuxed."
)]
pub struct Args {
    /// Select the input extension instead of discovering it.
    #[arg(long = "ext", value_enum, ignore_case = true)]
    pub input_extension: Option<MediaExtension>,

    /// Directory containing the ordered media parts.
    #[arg(default_value = ".")]
    pub directory: PathBuf,

    /// Output path; defaults to DIRECTORY/DIRECTORY-BASENAME.ext.
    pub output: Option<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StreamKind {
    Video,
    Audio,
    Subtitle,
    Other(String),
}

impl StreamKind {
    fn from_probe(value: String) -> Self {
        match value.as_str() {
            "video" => Self::Video,
            "audio" => Self::Audio,
            "subtitle" => Self::Subtitle,
            _ => Self::Other(value),
        }
    }

    fn label(&self) -> &str {
        match self {
            Self::Video => "video",
            Self::Audio => "audio",
            Self::Subtitle => "subtitle",
            Self::Other(value) => value,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaStream {
    pub codec_name: String,
    pub index: u32,
    pub kind: StreamKind,
}

pub trait MediaBackend {
    /// Concatenate normalized container files described by `list`.
    ///
    /// # Errors
    ///
    /// Returns an error when the media tool cannot produce `output`.
    fn concat_normalized(&mut self, list: &Path, output: &Path) -> Result<()>;

    /// Copy all streams from `input` while normalizing its timestamps.
    ///
    /// # Errors
    ///
    /// Returns an error when the media tool cannot produce `output`.
    fn normalize(&mut self, input: &Path, output: &Path) -> Result<()>;

    /// Inspect the streams exposed by an `FFmpeg` concat manifest.
    ///
    /// # Errors
    ///
    /// Returns an error when the probe fails or returns invalid data.
    fn probe_concat(&mut self, list: &Path) -> Result<Vec<MediaStream>>;

    /// Remux selected stream indexes from an `FFmpeg` concat manifest.
    ///
    /// # Errors
    ///
    /// Returns an error when the media tool cannot produce `output`.
    fn remux_concat(&mut self, list: &Path, maps: &[u32], output: &Path) -> Result<()>;
}

#[derive(Default)]
pub struct FfmpegBackend;

impl FfmpegBackend {
    // FFmpeg owns the container and codec behavior here. Its versioned CLI is
    // a narrower and safer boundary than binding this small orchestrator to
    // the unsafe libav C API; all filesystem and manifest work stays native.
    fn checked_status(command: &mut Command, description: &str) -> Result<()> {
        let status = command
            .status()
            .with_context(|| format!("failed to start {description}"))?;
        if !status.success() {
            bail!("{description} exited with {status}");
        }
        Ok(())
    }
}

impl MediaBackend for FfmpegBackend {
    fn concat_normalized(&mut self, list: &Path, output: &Path) -> Result<()> {
        Self::checked_status(
            Command::new(FFMPEG)
                .args([
                    "-hide_banner",
                    "-loglevel",
                    "warning",
                    "-y",
                    "-f",
                    "concat",
                    "-safe",
                    "0",
                    "-i",
                ])
                .arg(list)
                .args(["-map", "0", "-c", "copy"])
                .arg(output),
            "ffmpeg media concatenation",
        )
    }

    fn normalize(&mut self, input: &Path, output: &Path) -> Result<()> {
        Self::checked_status(
            Command::new(FFMPEG)
                .args([
                    "-hide_banner",
                    "-loglevel",
                    "warning",
                    "-y",
                    "-fflags",
                    "+genpts+igndts",
                    "-i",
                ])
                .arg(input)
                .args(["-map", "0", "-c", "copy", "-avoid_negative_ts", "make_zero"])
                .arg(output),
            &format!("ffmpeg timestamp normalization for {}", input.display()),
        )
    }

    fn probe_concat(&mut self, list: &Path) -> Result<Vec<MediaStream>> {
        let output = Command::new(FFPROBE)
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-show_entries",
                "stream=index,codec_type,codec_name",
                "-of",
                "json",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
            ])
            .arg(list)
            .output()
            .context("failed to start ffprobe stream inspection")?;
        if !output.status.success() {
            bail!("ffprobe stream inspection exited with {}", output.status);
        }
        let response: ProbeResponse =
            serde_json::from_slice(&output.stdout).context("ffprobe returned invalid JSON")?;
        Ok(response
            .streams
            .into_iter()
            .map(|stream| MediaStream {
                codec_name: stream.codec_name,
                index: stream.index,
                kind: StreamKind::from_probe(stream.codec_type),
            })
            .collect())
    }

    fn remux_concat(&mut self, list: &Path, maps: &[u32], output: &Path) -> Result<()> {
        let mut command = Command::new(FFMPEG);
        command
            .args([
                "-hide_banner",
                "-loglevel",
                "warning",
                "-y",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
            ])
            .arg(list);
        for index in maps {
            command.args(["-map", &format!("0:{index}")]);
        }
        command.args(["-c", "copy"]).arg(output);
        Self::checked_status(&mut command, "ffmpeg TS remux")
    }
}

#[derive(Debug, Deserialize)]
struct ProbeResponse {
    streams: Vec<ProbeStream>,
}

#[derive(Debug, Deserialize)]
struct ProbeStream {
    codec_name: String,
    codec_type: String,
    index: u32,
}

/// Discover and join the selected directory's ordered media parts.
///
/// # Errors
///
/// Returns an error for invalid input, filesystem failures, or a failed media
/// operation.
pub fn run(
    arguments: Args,
    backend: &mut impl MediaBackend,
    stdout: &mut impl Write,
    stderr: &mut impl Write,
) -> Result<PathBuf> {
    let directory = arguments.directory.canonicalize().with_context(|| {
        format!(
            "input directory not found: {}",
            arguments.directory.display()
        )
    })?;
    if !directory.is_dir() {
        bail!(
            "input directory not found: {}",
            arguments.directory.display()
        );
    }

    let input_extension = match arguments.input_extension {
        Some(extension) => extension,
        None => discover_extension(&directory)?,
    };
    let parts = discover_parts(&directory, input_extension)?;
    let output = match arguments.output {
        Some(path) => path,
        None => default_output_path(&directory, input_extension)?,
    };
    if output.try_exists()? {
        bail!("output already exists: {}", output.display());
    }
    let output_extension = output_extension(&output)?;

    writeln!(
        stdout,
        "joining {} .{} parts from {}",
        parts.len(),
        input_extension.as_str(),
        directory.display()
    )?;
    for part in &parts {
        writeln!(stdout, "  {}", part.display())?;
    }

    match input_extension {
        MediaExtension::Ts => join_ts(&parts, output_extension, &output, backend, stderr)?,
        MediaExtension::Mp4 | MediaExtension::Mkv => {
            join_container_parts(
                &directory,
                &parts,
                output_extension,
                &output,
                backend,
                stdout,
            )?;
        }
    }
    writeln!(stdout, "wrote {}", output.display())?;
    Ok(output)
}

fn discover_extension(directory: &Path) -> Result<MediaExtension> {
    let candidates = [MediaExtension::Ts, MediaExtension::Mp4, MediaExtension::Mkv]
        .into_iter()
        .filter(|extension| discover_parts(directory, *extension).is_ok())
        .collect::<Vec<_>>();
    match candidates.as_slice() {
        [] => bail!(
            "could not find at least two matching .ts, .mp4, or .mkv files in {}",
            directory.display()
        ),
        [extension] => Ok(*extension),
        _ => bail!(
            "multiple candidate extensions found in {}: {}; rerun with --ext <ts|mp4|mkv>",
            directory.display(),
            candidates
                .iter()
                .map(|extension| extension.as_str())
                .collect::<Vec<_>>()
                .join(" ")
        ),
    }
}

fn discover_parts(directory: &Path, extension: MediaExtension) -> Result<Vec<PathBuf>> {
    let mut parts = fs::read_dir(directory)
        .with_context(|| format!("failed to read {}", directory.display()))?
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| value.eq_ignore_ascii_case(extension.as_str()))
        })
        .collect::<Vec<_>>();
    parts.sort_by(|left, right| natural_path_cmp(left, right));
    if parts.len() < 2 {
        bail!(
            "need at least two .{} files in {}",
            extension.as_str(),
            directory.display()
        );
    }
    Ok(parts)
}

fn natural_path_cmp(left: &Path, right: &Path) -> Ordering {
    let left_name = left
        .file_name()
        .unwrap_or(left.as_os_str())
        .to_string_lossy();
    let right_name = right
        .file_name()
        .unwrap_or(right.as_os_str())
        .to_string_lossy();
    natord::compare(&left_name, &right_name).then_with(|| left.cmp(right))
}

fn default_output_path(directory: &Path, input_extension: MediaExtension) -> Result<PathBuf> {
    let basename = directory
        .file_name()
        .context("cannot derive an output name for the filesystem root")?
        .to_string_lossy();
    Ok(directory.join(format!(
        "{basename}.{}",
        input_extension.default_output().as_str()
    )))
}

fn output_extension(output: &Path) -> Result<MediaExtension> {
    let extension = output
        .extension()
        .and_then(|value| value.to_str())
        .context("output path must have a .ts, .mp4, or .mkv extension")?;
    if extension.eq_ignore_ascii_case("ts") {
        Ok(MediaExtension::Ts)
    } else if extension.eq_ignore_ascii_case("mp4") {
        Ok(MediaExtension::Mp4)
    } else if extension.eq_ignore_ascii_case("mkv") {
        Ok(MediaExtension::Mkv)
    } else {
        bail!("unsupported output extension: .{extension}");
    }
}

fn join_ts(
    parts: &[PathBuf],
    output_extension: MediaExtension,
    output: &Path,
    backend: &mut impl MediaBackend,
    stderr: &mut impl Write,
) -> Result<()> {
    match output_extension {
        MediaExtension::Ts => concatenate_files(parts, output),
        MediaExtension::Mkv | MediaExtension::Mp4 => {
            let temp = Builder::new()
                .prefix(".join-media-parts.")
                .tempdir_in(parts[0].parent().context("input part has no parent")?)?;
            let list = temp.path().join("concat.txt");
            write_concat_file(&list, parts)?;
            remux_ts_streams(&list, output_extension, output, backend, stderr)
        }
    }
}

fn concatenate_files(parts: &[PathBuf], output: &Path) -> Result<()> {
    let parent = output.parent().unwrap_or_else(|| Path::new("."));
    let mut temporary = NamedTempFile::new_in(parent)
        .with_context(|| format!("failed to create temporary output in {}", parent.display()))?;
    for part in parts {
        let mut input = File::open(part)
            .with_context(|| format!("failed to open input part {}", part.display()))?;
        io::copy(&mut input, temporary.as_file_mut())
            .with_context(|| format!("failed to concatenate {}", part.display()))?;
    }
    temporary
        .persist_noclobber(output)
        .map_err(|error| error.error)
        .with_context(|| format!("failed to persist output {}", output.display()))?;
    Ok(())
}

fn remux_ts_streams(
    list: &Path,
    output_extension: MediaExtension,
    output: &Path,
    backend: &mut impl MediaBackend,
    stderr: &mut impl Write,
) -> Result<()> {
    let streams = backend.probe_concat(list)?;
    let mut selected_maps = Vec::new();
    let mut av_maps = Vec::new();
    let mut skipped = Vec::new();
    for stream in streams {
        match stream.kind {
            StreamKind::Video | StreamKind::Audio => {
                selected_maps.push(stream.index);
                av_maps.push(stream.index);
            }
            StreamKind::Subtitle
                if output_extension == MediaExtension::Mkv
                    && stream.codec_name != "dvb_teletext" =>
            {
                selected_maps.push(stream.index);
            }
            kind => skipped.push(format!(
                "{} stream {} ({})",
                kind.label(),
                stream.index,
                stream.codec_name
            )),
        }
    }
    if av_maps.is_empty() {
        bail!("could not find any audio or video streams in input TS parts");
    }
    if !skipped.is_empty() {
        writeln!(
            stderr,
            "skipping incompatible streams for .{} output:",
            output_extension.as_str()
        )?;
        for stream in skipped {
            writeln!(stderr, "  {stream}")?;
        }
    }
    match backend.remux_concat(list, &selected_maps, output) {
        Ok(()) => Ok(()),
        Err(error) if selected_maps.len() > av_maps.len() => {
            writeln!(
                stderr,
                "remux failed with subtitle streams; retrying with video/audio streams only"
            )?;
            backend.remux_concat(list, &av_maps, output).context(error)
        }
        Err(error) => Err(error),
    }
}

fn join_container_parts(
    directory: &Path,
    parts: &[PathBuf],
    output_extension: MediaExtension,
    output: &Path,
    backend: &mut impl MediaBackend,
    stdout: &mut impl Write,
) -> Result<()> {
    if output_extension == MediaExtension::Ts {
        bail!("unsupported output extension for container input: .ts (expected .mkv or .mp4)");
    }
    let temp = Builder::new()
        .prefix(".join-media-parts.")
        .tempdir_in(directory)?;
    let normalized_directory = temp.path().join("normalized");
    fs::create_dir(&normalized_directory)?;
    let mut normalized = Vec::new();
    for (index, part) in parts.iter().enumerate() {
        let name = part
            .file_name()
            .unwrap_or(part.as_os_str())
            .to_string_lossy();
        writeln!(stdout, "normalizing timestamps for {name}")?;
        let normalized_part = normalized_directory.join(format!("{:04}.mkv", index + 1));
        backend.normalize(part, &normalized_part)?;
        normalized.push(normalized_part);
    }
    let list = temp.path().join("concat.txt");
    write_concat_file(&list, &normalized)?;
    backend.concat_normalized(&list, output)
}

fn write_concat_file(destination: &Path, parts: &[PathBuf]) -> Result<()> {
    let mut file = File::create(destination)
        .with_context(|| format!("failed to create {}", destination.display()))?;
    for part in parts {
        let path = part
            .to_str()
            .with_context(|| format!("media path is not UTF-8: {}", part.display()))?;
        // FFmpeg's concat demuxer parses a shell-like token syntax. Close the
        // quoted token around an apostrophe, escape it, and resume quoting.
        let escaped = path.replace('\'', "'\\''");
        writeln!(file, "file '{escaped}'")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    #[derive(Default)]
    struct FakeBackend {
        concat_calls: usize,
        normalizations: Vec<String>,
        probe_streams: Vec<MediaStream>,
        remux_maps: Vec<Vec<u32>>,
        remux_results: VecDeque<Result<()>>,
    }

    impl MediaBackend for FakeBackend {
        fn concat_normalized(&mut self, _list: &Path, output: &Path) -> Result<()> {
            self.concat_calls += 1;
            fs::write(output, b"joined")?;
            Ok(())
        }

        fn normalize(&mut self, input: &Path, output: &Path) -> Result<()> {
            self.normalizations.push(
                input
                    .file_name()
                    .unwrap_or(input.as_os_str())
                    .to_string_lossy()
                    .into_owned(),
            );
            fs::write(output, b"normalized")?;
            Ok(())
        }

        fn probe_concat(&mut self, _list: &Path) -> Result<Vec<MediaStream>> {
            Ok(self.probe_streams.clone())
        }

        fn remux_concat(&mut self, _list: &Path, maps: &[u32], output: &Path) -> Result<()> {
            self.remux_maps.push(maps.to_vec());
            let result = self.remux_results.pop_front().unwrap_or(Ok(()));
            if result.is_ok() {
                fs::write(output, b"remuxed")?;
            }
            result
        }
    }

    fn args(directory: &Path, extension: MediaExtension, output: Option<PathBuf>) -> Args {
        Args {
            input_extension: Some(extension),
            directory: directory.to_owned(),
            output,
        }
    }

    #[test]
    fn direct_ts_output_concatenates_naturally_ordered_parts() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("part10.ts"), b"ten").unwrap();
        fs::write(temp.path().join("part2.TS"), b"two").unwrap();
        let output = temp.path().join("result.ts");

        run(
            args(temp.path(), MediaExtension::Ts, Some(output.clone())),
            &mut FakeBackend::default(),
            &mut Vec::new(),
            &mut Vec::new(),
        )
        .unwrap();

        assert_eq!(fs::read(output).unwrap(), b"twoten");
    }

    #[test]
    fn cli_accepts_case_insensitive_input_extensions() {
        let arguments = Args::try_parse_from(["join-media-parts", "--ext", "MP4"]).unwrap();

        assert_eq!(arguments.input_extension, Some(MediaExtension::Mp4));
    }

    #[test]
    fn discovery_rejects_ambiguous_extensions() {
        let temp = tempfile::tempdir().unwrap();
        for name in ["1.ts", "2.ts", "1.mp4", "2.mp4"] {
            fs::write(temp.path().join(name), b"part").unwrap();
        }

        let error = run(
            Args {
                input_extension: None,
                directory: temp.path().to_owned(),
                output: None,
            },
            &mut FakeBackend::default(),
            &mut Vec::new(),
            &mut Vec::new(),
        )
        .unwrap_err();

        assert!(error.to_string().contains("multiple candidate extensions"));
    }

    #[test]
    fn ts_remux_retries_without_subtitles_and_skips_incompatible_streams() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("1.ts"), b"one").unwrap();
        fs::write(temp.path().join("2.ts"), b"two").unwrap();
        let output = temp.path().join("result.mkv");
        let mut backend = FakeBackend {
            probe_streams: vec![
                MediaStream {
                    codec_name: "h264".to_owned(),
                    index: 0,
                    kind: StreamKind::Video,
                },
                MediaStream {
                    codec_name: "aac".to_owned(),
                    index: 1,
                    kind: StreamKind::Audio,
                },
                MediaStream {
                    codec_name: "subrip".to_owned(),
                    index: 2,
                    kind: StreamKind::Subtitle,
                },
                MediaStream {
                    codec_name: "bin_data".to_owned(),
                    index: 3,
                    kind: StreamKind::Other("data".to_owned()),
                },
            ],
            remux_results: VecDeque::from([Err(anyhow::anyhow!("bad subtitle")), Ok(())]),
            ..Default::default()
        };
        let mut stderr = Vec::new();

        run(
            args(temp.path(), MediaExtension::Ts, Some(output)),
            &mut backend,
            &mut Vec::new(),
            &mut stderr,
        )
        .unwrap();

        assert_eq!(backend.remux_maps, [vec![0, 1, 2], vec![0, 1]]);
        let stderr = String::from_utf8(stderr).unwrap();
        assert!(stderr.contains("data stream 3 (bin_data)"));
        assert!(stderr.contains("retrying with video/audio streams only"));
    }

    #[test]
    fn mp4_parts_are_normalized_in_natural_order_before_concat() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("Part 10.mp4"), b"ten").unwrap();
        fs::write(temp.path().join("Part 2.mp4"), b"two").unwrap();
        let output = temp.path().join("result.mp4");
        let mut backend = FakeBackend::default();

        run(
            args(temp.path(), MediaExtension::Mp4, Some(output)),
            &mut backend,
            &mut Vec::new(),
            &mut Vec::new(),
        )
        .unwrap();

        assert_eq!(backend.normalizations, ["Part 2.mp4", "Part 10.mp4"]);
        assert_eq!(backend.concat_calls, 1);
    }

    #[test]
    fn concat_manifest_escapes_apostrophes_for_ffmpeg() {
        let temp = tempfile::tempdir().unwrap();
        let destination = temp.path().join("concat.txt");
        write_concat_file(&destination, &[PathBuf::from("/media/it's ready.ts")]).unwrap();

        assert_eq!(
            fs::read_to_string(destination).unwrap(),
            "file '/media/it'\\''s ready.ts'\n"
        );
    }

    #[test]
    fn existing_output_is_rejected_before_backend_side_effects() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("1.mkv"), b"one").unwrap();
        fs::write(temp.path().join("2.mkv"), b"two").unwrap();
        let output = temp.path().join("result.mkv");
        fs::write(&output, b"existing").unwrap();
        let mut backend = FakeBackend::default();

        let error = run(
            args(temp.path(), MediaExtension::Mkv, Some(output)),
            &mut backend,
            &mut Vec::new(),
            &mut Vec::new(),
        )
        .unwrap_err();

        assert!(error.to_string().contains("output already exists"));
        assert!(backend.normalizations.is_empty());
        assert_eq!(backend.concat_calls, 0);
    }
}
