use std::collections::BTreeMap;
use std::io;

pub const DEFAULT_PROMPT: &str = "OpenSSH authentication";

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Request {
    AlreadyConfirmed,
    UserPresence(String),
    Confirmation(String),
    Secret(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Outcome {
    pub standard_output: String,
    pub status: i32,
}

impl Outcome {
    pub fn success(standard_output: impl Into<String>) -> Self {
        Self {
            standard_output: standard_output.into(),
            status: 0,
        }
    }

    pub fn cancelled() -> Self {
        Self {
            standard_output: String::new(),
            status: 1,
        }
    }
}

pub trait Prompting {
    fn await_user_presence(&mut self, prompt: &str) -> io::Result<bool>;
    fn confirm(&mut self, prompt: &str) -> io::Result<bool>;
    fn read_secret(&mut self, prompt: &str) -> io::Result<Option<String>>;
}

pub fn graphical_available(environment: &BTreeMap<String, String>) -> bool {
    ["DISPLAY", "WAYLAND_DISPLAY"]
        .into_iter()
        .any(|name| environment.get(name).is_some_and(|value| !value.is_empty()))
}

pub fn request(arguments: &[String], environment: &BTreeMap<String, String>) -> Request {
    let prompt = arguments
        .first()
        .filter(|argument| !argument.is_empty())
        .cloned()
        .unwrap_or_else(|| DEFAULT_PROMPT.to_owned());

    if prompt.starts_with("User presence confirmed") {
        Request::AlreadyConfirmed
    } else if prompt.starts_with("Confirm user presence for key ") {
        Request::UserPresence(prompt)
    } else if environment
        .get("SSH_ASKPASS_PROMPT")
        .is_some_and(|value| value == "confirm")
    {
        Request::Confirmation(prompt)
    } else {
        Request::Secret(prompt)
    }
}

pub fn execute(request: Request, prompter: &mut impl Prompting) -> io::Result<Outcome> {
    match request {
        Request::AlreadyConfirmed => Ok(Outcome::success("")),
        Request::UserPresence(prompt) => {
            boolean_outcome(prompter.await_user_presence(&prompt)?, "")
        }
        Request::Confirmation(prompt) => boolean_outcome(prompter.confirm(&prompt)?, "yes\n"),
        Request::Secret(prompt) => Ok(match prompter.read_secret(&prompt)? {
            Some(secret) => Outcome::success(format!("{secret}\n")),
            None => Outcome::cancelled(),
        }),
    }
}

fn boolean_outcome(accepted: bool, output: &str) -> io::Result<Outcome> {
    Ok(if accepted {
        Outcome::success(output)
    } else {
        Outcome::cancelled()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct RecordingPrompter {
        presence: bool,
        confirmation: bool,
        secret: Option<String>,
        presence_prompts: Vec<String>,
        confirmation_prompts: Vec<String>,
        secret_prompts: Vec<String>,
    }

    impl Prompting for RecordingPrompter {
        fn await_user_presence(&mut self, prompt: &str) -> io::Result<bool> {
            self.presence_prompts.push(prompt.to_owned());
            Ok(self.presence)
        }

        fn confirm(&mut self, prompt: &str) -> io::Result<bool> {
            self.confirmation_prompts.push(prompt.to_owned());
            Ok(self.confirmation)
        }

        fn read_secret(&mut self, prompt: &str) -> io::Result<Option<String>> {
            self.secret_prompts.push(prompt.to_owned());
            Ok(self.secret.clone())
        }
    }

    fn environment(values: &[(&str, &str)]) -> BTreeMap<String, String> {
        values
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn classifies_openssh_prompt_modes() {
        assert_eq!(
            request(&[], &environment(&[])),
            Request::Secret(DEFAULT_PROMPT.to_owned())
        );
        assert_eq!(
            request(&[String::new()], &environment(&[])),
            Request::Secret(DEFAULT_PROMPT.to_owned())
        );
        assert_eq!(
            request(
                &["Password:".to_owned(), "ignored".to_owned()],
                &environment(&[])
            ),
            Request::Secret("Password:".to_owned())
        );
        assert_eq!(
            request(
                &["Use this key?".to_owned()],
                &environment(&[("SSH_ASKPASS_PROMPT", "confirm")])
            ),
            Request::Confirmation("Use this key?".to_owned())
        );
        assert_eq!(
            request(
                &["Confirm user presence for key ED25519".to_owned()],
                &environment(&[("SSH_ASKPASS_PROMPT", "confirm")])
            ),
            Request::UserPresence("Confirm user presence for key ED25519".to_owned())
        );
        assert_eq!(
            request(
                &["User presence confirmed for key ED25519".to_owned()],
                &environment(&[])
            ),
            Request::AlreadyConfirmed
        );
    }

    #[test]
    fn detects_graphical_display_from_either_environment_variable() {
        assert!(!graphical_available(&environment(&[])));
        assert!(!graphical_available(&environment(&[
            ("DISPLAY", ""),
            ("WAYLAND_DISPLAY", ""),
        ])));
        assert!(graphical_available(&environment(&[("DISPLAY", ":0")])));
        assert!(graphical_available(&environment(&[(
            "WAYLAND_DISPLAY",
            "wayland-1",
        )])));
    }

    #[test]
    fn returns_password_and_confirmation_output() {
        let mut prompter = RecordingPrompter {
            confirmation: true,
            secret: Some("hunter2".to_owned()),
            ..RecordingPrompter::default()
        };
        assert_eq!(
            execute(Request::Secret("Password:".to_owned()), &mut prompter).unwrap(),
            Outcome::success("hunter2\n")
        );
        assert_eq!(
            execute(Request::Confirmation("Allow?".to_owned()), &mut prompter).unwrap(),
            Outcome::success("yes\n")
        );
        assert_eq!(prompter.secret_prompts, ["Password:"]);
        assert_eq!(prompter.confirmation_prompts, ["Allow?"]);
    }

    #[test]
    fn maps_rejection_and_cancellation_to_status_one() {
        let mut prompter = RecordingPrompter::default();
        assert_eq!(
            execute(Request::Confirmation("Allow?".to_owned()), &mut prompter).unwrap(),
            Outcome::cancelled()
        );
        assert_eq!(
            execute(Request::Secret("Password:".to_owned()), &mut prompter).unwrap(),
            Outcome::cancelled()
        );
    }

    #[test]
    fn handles_user_presence_without_secret_output() {
        let mut prompter = RecordingPrompter {
            presence: true,
            ..RecordingPrompter::default()
        };
        assert_eq!(
            execute(Request::UserPresence("Touch key".to_owned()), &mut prompter).unwrap(),
            Outcome::success("")
        );
        assert_eq!(prompter.presence_prompts, ["Touch key"]);

        assert_eq!(
            execute(Request::AlreadyConfirmed, &mut prompter).unwrap(),
            Outcome::success("")
        );
        assert_eq!(prompter.presence_prompts, ["Touch key"]);
    }
}
