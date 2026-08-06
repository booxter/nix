use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub mod check_target;
pub mod deploy;
pub mod deploy_remote;
pub mod deploy_source;
pub mod diff;
mod repository;
pub mod vm;
pub mod wireguard;

const COMPILED_HOSTS_JSON: &str = env!("FLEET_HOSTS_JSON");

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Host {
    pub display_name: String,
    pub is_work: bool,
    pub platform: String,
    pub runtime_host: String,
    pub ssh_host: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostInventory {
    pub aliases: BTreeMap<String, String>,
    pub darwin: BTreeMap<String, Host>,
    pub lan_dns_server: String,
    pub lan_domain: String,
    pub nixos: BTreeMap<String, Host>,
}

pub fn compiled_inventory() -> Result<HostInventory, serde_json::Error> {
    serde_json::from_str(COMPILED_HOSTS_JSON)
}

pub fn select_hosts(inventory: &HostInventory, requested: &[String]) -> HostInventory {
    if requested.is_empty() {
        return inventory.clone();
    }

    HostInventory {
        aliases: inventory.aliases.clone(),
        darwin: select_platform(&inventory.darwin, requested),
        lan_dns_server: inventory.lan_dns_server.clone(),
        lan_domain: inventory.lan_domain.clone(),
        nixos: select_platform(&inventory.nixos, requested),
    }
}

fn select_platform(hosts: &BTreeMap<String, Host>, requested: &[String]) -> BTreeMap<String, Host> {
    requested
        .iter()
        .filter_map(|name| hosts.get(name).map(|host| (name.clone(), host.clone())))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{compiled_inventory, select_hosts};

    #[test]
    fn compiled_inventory_classifies_darwin_and_nixos_hosts() {
        let inventory = compiled_inventory().expect("compiled host inventory should be valid");

        assert!(!inventory.darwin["mair"].is_work);
        assert_eq!(inventory.darwin["mair"].platform, "aarch64-darwin");
        assert_eq!(inventory.darwin["mair"].runtime_host, "mair");
        assert!(!inventory.nixos["beast"].is_work);
        assert_eq!(inventory.nixos["beast"].platform, "x86_64-linux");
        assert!(inventory.nixos["nv"].is_work);
        assert_eq!(inventory.aliases["JGWXHWDL4X"], "JGWXHWDL4X");
        assert!(!inventory.lan_dns_server.is_empty());
        assert!(!inventory.lan_domain.is_empty());
    }

    #[test]
    fn selection_filters_both_platforms_and_ignores_unknown_hosts() {
        let inventory = compiled_inventory().expect("compiled host inventory should be valid");
        let selected = select_hosts(
            &inventory,
            &[
                "mair".to_owned(),
                "nvws".to_owned(),
                "beast".to_owned(),
                "unknown".to_owned(),
            ],
        );

        assert_eq!(
            selected
                .darwin
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["mair"]
        );
        assert_eq!(
            selected
                .nixos
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["beast", "nvws"]
        );
        assert!(selected.nixos["nvws"].is_work);
        assert_eq!(selected.aliases, inventory.aliases);
    }
}
