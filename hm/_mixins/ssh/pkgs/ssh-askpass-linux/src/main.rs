use std::collections::BTreeMap;
use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use rustix::termios::{self, LocalModes, OptionalActions, Termios};
use ssh_askpass_linux::{execute, graphical_available, request, Prompting};

const ZENITY: &str = env!("ZENITY");

fn main() {
    match run() {
        Ok(status) => std::process::exit(status),
        Err(error) => {
            eprintln!("ssh-askpass-linux: {error}");
            std::process::exit(1);
        }
    }
}

fn run() -> io::Result<i32> {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    let environment = env::vars().collect::<BTreeMap<_, _>>();
    let request = request(&arguments, &environment);
    let mut prompter = SystemPrompter {
        graphical: graphical_available(&environment),
    };
    let outcome = execute(request, &mut prompter)?;
    let mut standard_output = io::stdout().lock();
    standard_output.write_all(outcome.standard_output.as_bytes())?;
    standard_output.flush()?;
    Ok(outcome.status)
}

struct SystemPrompter {
    graphical: bool,
}

impl Prompting for SystemPrompter {
    fn await_user_presence(&mut self, prompt: &str) -> io::Result<bool> {
        if self.graphical {
            return Ok(Command::new(ZENITY)
                .args([
                    "--info",
                    "--title",
                    "OpenSSH security key",
                    "--width",
                    "460",
                    "--ok-label",
                    "Dismiss",
                    "--text",
                    prompt,
                ])
                .stderr(Stdio::null())
                .status()?
                .success());
        }

        let mut tty = open_tty()?;
        write!(tty, "{prompt} [press Enter] ")?;
        tty.flush()?;
        Ok(read_line(&tty)?.is_some())
    }

    fn confirm(&mut self, prompt: &str) -> io::Result<bool> {
        if self.graphical {
            return Ok(Command::new(ZENITY)
                .args([
                    "--question",
                    "--title",
                    "OpenSSH authentication",
                    "--width",
                    "460",
                    "--ok-label",
                    "Yes",
                    "--cancel-label",
                    "No",
                    "--text",
                    prompt,
                ])
                .stderr(Stdio::null())
                .status()?
                .success());
        }

        let mut tty = open_tty()?;
        write!(tty, "{prompt} [y/N] ")?;
        tty.flush()?;
        Ok(read_line(&tty)?
            .is_some_and(|answer| matches!(answer.as_str(), "y" | "Y" | "yes" | "YES" | "Yes")))
    }

    fn read_secret(&mut self, prompt: &str) -> io::Result<Option<String>> {
        if self.graphical {
            let output = Command::new(ZENITY)
                .args([
                    "--entry",
                    "--title",
                    "OpenSSH authentication",
                    "--text",
                    prompt,
                    "--hide-text",
                ])
                .stderr(Stdio::null())
                .output()?;
            if !output.status.success() {
                return Ok(None);
            }
            let answer = String::from_utf8(output.stdout)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            return Ok(Some(answer.trim_end_matches('\n').to_owned()));
        }

        let mut tty = open_tty()?;
        write!(tty, "{prompt}")?;
        tty.flush()?;

        let saved = termios::tcgetattr(&tty)?;
        let mut hidden = saved.clone();
        hidden.local_modes.remove(LocalModes::ECHO);
        termios::tcsetattr(&tty, OptionalActions::Now, &hidden)?;
        let guard = TerminalGuard {
            saved,
            terminal: &tty,
        };
        let answer = read_line(&tty)?;
        drop(guard);
        writeln!(tty)?;
        Ok(answer)
    }
}

fn open_tty() -> io::Result<File> {
    OpenOptions::new().read(true).write(true).open("/dev/tty")
}

fn read_line(terminal: &File) -> io::Result<Option<String>> {
    let mut answer = String::new();
    let count = BufReader::new(terminal.try_clone()?).read_line(&mut answer)?;
    if count == 0 {
        return Ok(None);
    }
    if answer.ends_with('\n') {
        answer.pop();
    }
    Ok(Some(answer))
}

struct TerminalGuard<'a> {
    saved: Termios,
    terminal: &'a File,
}

impl Drop for TerminalGuard<'_> {
    fn drop(&mut self) {
        let _ = termios::tcsetattr(self.terminal, OptionalActions::Now, &self.saved);
    }
}
