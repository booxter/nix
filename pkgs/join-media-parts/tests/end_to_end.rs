use std::fs;
use std::path::Path;
use std::process::Command;

use serde::Deserialize;

const FFMPEG: &str = env!("JOIN_MEDIA_PARTS_FFMPEG");
const FFPROBE: &str = env!("JOIN_MEDIA_PARTS_FFPROBE");

#[derive(Deserialize)]
struct ProbeResponse {
    streams: Vec<ProbeStream>,
}

#[derive(Deserialize)]
struct ProbeStream {
    codec_type: String,
}

fn run(command: &mut Command, description: &str) {
    let status = command.status().unwrap_or_else(|error| {
        panic!("failed to start {description}: {error}");
    });
    assert!(status.success(), "{description} exited with {status}");
}

fn make_ts(path: &Path, color: &str, frequency: &str) {
    run(
        Command::new(FFMPEG)
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                &format!("color=c={color}:s=64x64:r=25:d=0.2"),
                "-f",
                "lavfi",
                "-i",
                &format!("sine=frequency={frequency}:sample_rate=48000:d=0.2"),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-f",
                "mpegts",
                "-c:a",
                "mp2",
                "-shortest",
            ])
            .arg(path),
        "ffmpeg TS fixture generation",
    );
}

fn make_mp4(path: &Path, color: &str) {
    run(
        Command::new(FFMPEG)
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                &format!("color=c={color}:s=64x64:r=25:d=0.2"),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
            ])
            .arg(path),
        "ffmpeg MP4 fixture generation",
    );
}

fn verify_media(path: &Path, expected_streams: &[&str]) {
    let output = Command::new(FFPROBE)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-show_entries",
            "stream=codec_type",
            "-of",
            "json",
        ])
        .arg(path)
        .output()
        .unwrap();
    assert!(output.status.success(), "ffprobe output validation failed");
    let response: ProbeResponse = serde_json::from_slice(&output.stdout).unwrap();
    let mut actual = response
        .streams
        .into_iter()
        .map(|stream| stream.codec_type)
        .collect::<Vec<_>>();
    actual.sort();
    assert_eq!(actual, expected_streams);
}

#[test]
fn joins_ts_and_mp4_parts_with_real_ffmpeg() {
    let temp = tempfile::tempdir().unwrap();
    let ts_directory = temp.path().join("ts case's parts");
    fs::create_dir(&ts_directory).unwrap();
    make_ts(&ts_directory.join("01_part.ts"), "black", "440");
    make_ts(&ts_directory.join("02_part.ts"), "blue", "880");

    run(
        Command::new(env!("CARGO_BIN_EXE_join-media-parts")).arg(&ts_directory),
        "join-media-parts TS workflow",
    );
    verify_media(
        &ts_directory.join("ts case's parts.mkv"),
        &["audio", "video"],
    );

    let mp4_directory = temp.path().join("mp4 case (sample)");
    fs::create_dir(&mp4_directory).unwrap();
    make_mp4(&mp4_directory.join("Part 01 (sample).mp4"), "red");
    make_mp4(&mp4_directory.join("Part 02 (sample).mp4"), "green");

    run(
        Command::new(env!("CARGO_BIN_EXE_join-media-parts")).arg(&mp4_directory),
        "join-media-parts MP4 workflow",
    );
    verify_media(&mp4_directory.join("mp4 case (sample).mp4"), &["video"]);
}
