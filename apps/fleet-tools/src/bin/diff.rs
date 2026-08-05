use std::process::ExitCode;

use clap::Parser;
use fleet_tools::diff::{execute, DiffOptions, GeneratedPath, TargetRequest};

const ABOUT: &str = "Build a NixOS or nix-darwin configuration at two Git revisions with nh, then render its package and closure-size diff with dix.";

const DETAILS: &str = "With --details, also diff generated system configuration, rendered nginx configuration, selected Homebrew recipes, and embedded Home Manager users. CA bundles, SSH moduli, terminfo, time zone databases, profile/manpage trees, and release metadata are omitted because their package changes are already covered by dix.";

#[derive(Debug, Parser)]
#[command(name = "diff", about = ABOUT, long_about = format!("{ABOUT}\n\n{DETAILS}"))]
struct Arguments {
    /// Include generated configuration details.
    #[arg(long)]
    details: bool,

    /// Override a generated system path; repeat for multiple paths.
    #[arg(long = "path", value_name = "RELPATH")]
    generated_paths: Vec<GeneratedPath>,

    /// Machine name or flake configuration attribute.
    target: TargetRequest,

    /// Git revision used for the old configuration.
    old_revision: String,

    /// Git revision used for the new configuration.
    new_revision: String,
}

fn main() -> ExitCode {
    let arguments = Arguments::parse();
    let options = DiffOptions {
        details: arguments.details || !arguments.generated_paths.is_empty(),
        generated_paths: arguments.generated_paths,
        target: arguments.target,
        old_revision: arguments.old_revision,
        new_revision: arguments.new_revision,
    };
    match execute(&options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::FAILURE
        }
    }
}
