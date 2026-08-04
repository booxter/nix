mod model;
mod system_backend;
mod workflow;

pub use model::DeployArgs;
use model::{
    ActivationRequest, Backend, DeploymentTarget, DiskoRequest, HostKind, SourceSelection,
    StagedSource,
};
pub use system_backend::SystemBackend;
#[cfg(test)]
use system_backend::{
    config_uses_proxy, dns_candidates, parse_store_path, remote_helper_arguments,
};
pub use workflow::run;
#[cfg(test)]
use workflow::{run_with_backend, REPO_URL};

#[cfg(test)]
mod tests;
