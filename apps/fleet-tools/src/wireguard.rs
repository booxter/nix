use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, ensure, Context, Result};
use clap::{ArgGroup, Parser};
use ipnet::Ipv4Net;
use serde::Deserialize;
use tempfile::NamedTempFile;

const COMPILED_CONFIG_JSON: &str = env!("WG_HOME_CONFIG_JSON");
const SSH_PROGRAM: &str = match option_env!("WG_HOME_SSH") {
    Some(path) => path,
    None => "ssh",
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WireguardTopology {
    pub subnet: Ipv4Net,
    pub dns: Vec<String>,
    pub endpoint: String,
    pub allowed_ips: Vec<Ipv4Net>,
    pub peers: BTreeMap<String, Ipv4Net>,
    pub gateway_ssh_host: String,
}

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Generate a home WireGuard client configuration",
    after_help = env!("WG_HOME_HELP"),
    group(
        ArgGroup::new("address-source")
            .required(true)
            .multiple(false)
            .args(["peer", "address"])
    ),
    group(
        ArgGroup::new("server-key-source")
            .required(true)
            .multiple(false)
            .args(["server_public_key", "fetch_server_public_key"])
    )
)]
pub struct WireguardArgs {
    /// Resolve the client address from this inventory peer.
    #[arg(long, value_name = "NAME")]
    pub peer: Option<String>,

    /// Use this explicit IPv4 /32 client address.
    #[arg(long, value_name = "ADDRESS")]
    pub address: Option<Ipv4Net>,

    /// Read the client private key from this file.
    #[arg(long, value_name = "PATH")]
    pub private_key_file: PathBuf,

    /// Use this WireGuard server public key.
    #[arg(long, value_name = "KEY")]
    pub server_public_key: Option<String>,

    /// Fetch the server public key from the WireGuard gateway.
    #[arg(long)]
    pub fetch_server_public_key: bool,

    /// Write the private configuration to this file instead of stdout.
    #[arg(long, value_name = "PATH")]
    pub output: Option<PathBuf>,
}

pub trait PublicKeyFetcher {
    fn fetch(&self, target: &str) -> Result<String>;
}

pub struct SshPublicKeyFetcher {
    executable: PathBuf,
}

impl Default for SshPublicKeyFetcher {
    fn default() -> Self {
        Self {
            executable: PathBuf::from(SSH_PROGRAM),
        }
    }
}

impl PublicKeyFetcher for SshPublicKeyFetcher {
    fn fetch(&self, target: &str) -> Result<String> {
        let output = Command::new(&self.executable)
            .args([target, "sudo", "wg", "show", "wg0", "public-key"])
            .output()
            .with_context(|| format!("failed to start {}", self.executable.display()))?;
        if !output.status.success() {
            bail!(
                "failed to fetch server public key over SSH: {}",
                output.status
            );
        }
        String::from_utf8(output.stdout).context("server public key is not UTF-8")
    }
}

pub fn compiled_topology() -> Result<WireguardTopology> {
    serde_json::from_str(COMPILED_CONFIG_JSON).context("compiled WireGuard topology is invalid")
}

pub fn run(
    arguments: WireguardArgs,
    public_key_fetcher: &impl PublicKeyFetcher,
    stdout: &mut impl Write,
) -> Result<()> {
    let topology = compiled_topology()?;
    let address = resolve_address(&topology, arguments.peer.as_deref(), arguments.address)?;
    let private_key = normalize_key(
        fs::read_to_string(&arguments.private_key_file)
            .with_context(|| format!("failed to read {}", arguments.private_key_file.display()))?,
    )?;
    let server_public_key = normalize_key(match arguments.server_public_key {
        Some(key) => key,
        None => public_key_fetcher.fetch(&topology.gateway_ssh_host)?,
    })?;
    let configuration = render_config(&topology, address, &private_key, &server_public_key);

    match arguments.output {
        Some(path) => write_private_file(&path, &configuration),
        None => stdout
            .write_all(configuration.as_bytes())
            .context("failed to write WireGuard configuration"),
    }
}

pub fn resolve_address(
    topology: &WireguardTopology,
    peer: Option<&str>,
    explicit: Option<Ipv4Net>,
) -> Result<Ipv4Net> {
    let address = match peer {
        Some(name) => *topology.peers.get(name).with_context(|| {
            let known = topology
                .peers
                .keys()
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");
            format!("unknown inventory peer '{name}'; known peers: {known}")
        })?,
        None => explicit.context("peer address is required")?,
    };

    ensure!(address.prefix_len() == 32, "peer address must use /32");
    ensure!(
        topology.subnet.contains(&address.addr()),
        "peer address {} is not inside {}",
        address.addr(),
        topology.subnet
    );
    Ok(address)
}

fn normalize_key(mut key: String) -> Result<String> {
    key.retain(|character| !matches!(character, '\n' | '\r'));
    ensure!(
        !key.is_empty(),
        "private key and server public key must be non-empty"
    );
    Ok(key)
}

fn render_config(
    topology: &WireguardTopology,
    address: Ipv4Net,
    private_key: &str,
    server_public_key: &str,
) -> String {
    format!(
        "[Interface]\n\
         PrivateKey = {private_key}\n\
         Address = {address}\n\
         DNS = {}\n\
         \n\
         [Peer]\n\
         PublicKey = {server_public_key}\n\
         Endpoint = {}\n\
         AllowedIPs = {}\n\
         PersistentKeepalive = 25\n",
        topology.dns.join(", "),
        topology.endpoint,
        topology
            .allowed_ips
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn write_private_file(path: &Path, content: &str) -> Result<()> {
    let directory = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut temporary = NamedTempFile::new_in(directory)
        .with_context(|| format!("failed to create output beside {}", path.display()))?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))
        .context("failed to set WireGuard configuration permissions")?;
    temporary
        .write_all(content.as_bytes())
        .context("failed to write WireGuard configuration")?;
    temporary
        .as_file()
        .sync_all()
        .context("failed to sync WireGuard configuration")?;
    temporary
        .persist(path)
        .map_err(|error| error.error)
        .with_context(|| format!("failed to install {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::Mutex;

    use anyhow::Result;
    use clap::{CommandFactory, Parser};
    use ipnet::Ipv4Net;

    use super::{
        compiled_topology, resolve_address, run, PublicKeyFetcher, WireguardArgs, WireguardTopology,
    };

    struct FakePublicKeyFetcher {
        key: String,
        targets: Mutex<Vec<String>>,
    }

    impl PublicKeyFetcher for FakePublicKeyFetcher {
        fn fetch(&self, target: &str) -> Result<String> {
            self.targets
                .lock()
                .expect("targets lock")
                .push(target.to_owned());
            Ok(self.key.clone())
        }
    }

    fn arguments(private_key_file: PathBuf) -> WireguardArgs {
        WireguardArgs {
            peer: Some("mair".to_owned()),
            address: None,
            private_key_file,
            server_public_key: Some("test-server-pubkey".to_owned()),
            fetch_server_public_key: false,
            output: None,
        }
    }

    #[test]
    fn compiled_topology_renders_inventory_peer_configuration() {
        let temporary = tempfile::tempdir().expect("temporary directory should be created");
        let private_key_file = temporary.path().join("client.key");
        fs::write(&private_key_file, "test-private-key\n").expect("private key should be written");
        let fetcher = FakePublicKeyFetcher {
            key: "unused".to_owned(),
            targets: Mutex::new(Vec::new()),
        };
        let mut output = Vec::new();

        run(arguments(private_key_file), &fetcher, &mut output)
            .expect("configuration should render");

        let output = String::from_utf8(output).expect("output should be UTF-8");
        assert!(output.contains("Address = 10.83.0.10/32"));
        assert!(output.contains("DNS = 192.168.0.1, home.arpa"));
        assert!(output.contains("AllowedIPs = 10.83.0.0/24, 192.168.0.0/16"));
        assert!(output.contains(&format!(
            "Endpoint = {}",
            compiled_topology().expect("topology should parse").endpoint
        )));
        assert!(fetcher.targets.lock().expect("targets lock").is_empty());
    }

    #[test]
    fn resolves_explicit_address_and_rejects_invalid_peers() {
        let topology = compiled_topology().expect("topology should parse");
        assert_eq!(
            resolve_address(
                &topology,
                None,
                Some("10.83.0.50/32".parse().expect("address should parse"))
            )
            .expect("address should resolve"),
            "10.83.0.50/32"
                .parse::<Ipv4Net>()
                .expect("address should parse")
        );

        let unknown =
            resolve_address(&topology, Some("nope"), None).expect_err("unknown peer should fail");
        assert!(unknown
            .to_string()
            .contains("unknown inventory peer 'nope'"));

        let outside = resolve_address(
            &topology,
            None,
            Some("10.84.0.50/32".parse().expect("address should parse")),
        )
        .expect_err("outside address should fail");
        assert!(outside.to_string().contains("is not inside 10.83.0.0/24"));
    }

    #[test]
    fn fetches_server_key_and_writes_private_output_atomically() {
        let temporary = tempfile::tempdir().expect("temporary directory should be created");
        let private_key_file = temporary.path().join("client.key");
        let output_file = temporary.path().join("client.conf");
        fs::write(&private_key_file, "test-private-key\n").expect("private key should be written");
        let mut arguments = arguments(private_key_file);
        arguments.server_public_key = None;
        arguments.fetch_server_public_key = true;
        arguments.output = Some(output_file.clone());
        let fetcher = FakePublicKeyFetcher {
            key: "test-server-pubkey\r\n".to_owned(),
            targets: Mutex::new(Vec::new()),
        };

        run(arguments, &fetcher, &mut Vec::new()).expect("configuration should be written");

        assert_eq!(
            *fetcher.targets.lock().expect("targets lock"),
            [compiled_topology()
                .expect("topology should parse")
                .gateway_ssh_host]
        );
        assert!(fs::read_to_string(&output_file)
            .expect("configuration should be readable")
            .contains("PublicKey = test-server-pubkey\n"));
        assert_eq!(
            fs::metadata(&output_file)
                .expect("output metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn clap_enforces_exactly_one_address_and_server_key_source() {
        let error = WireguardArgs::try_parse_from([
            "wg-home-client-config",
            "--peer",
            "mair",
            "--address",
            "10.83.0.50/32",
            "--private-key-file",
            "client.key",
            "--server-public-key",
            "key",
        ])
        .expect_err("conflicting address sources should fail");

        assert_eq!(error.kind(), clap::error::ErrorKind::ArgumentConflict);
    }

    #[test]
    fn help_lists_inventory_backed_peers() {
        let help = WireguardArgs::command().render_long_help().to_string();

        assert!(help.contains("--peer mair"));
        assert!(help.contains("Inventory-backed peers: mair"));
    }

    #[test]
    fn rejects_non_32_peer_address() {
        let topology = WireguardTopology {
            subnet: "10.83.0.0/24".parse().expect("subnet should parse"),
            dns: Vec::new(),
            endpoint: String::new(),
            allowed_ips: Vec::new(),
            peers: BTreeMap::new(),
            gateway_ssh_host: String::new(),
        };

        let error = resolve_address(
            &topology,
            None,
            Some("10.83.0.0/24".parse().expect("address should parse")),
        )
        .expect_err("non-/32 address should fail");

        assert!(error.to_string().contains("must use /32"));
    }
}
