use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub mod diff;
pub mod local_builders;
pub mod vm;
pub mod wireguard;

const COMPILED_HOSTS_JSON: &str = env!("FLEET_HOSTS_JSON");

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Host {
    pub is_work: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct HostInventory {
    pub darwin: BTreeMap<String, Host>,
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
        darwin: select_platform(&inventory.darwin, requested),
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
        assert!(!inventory.nixos["beast"].is_work);
        assert!(inventory.nixos["nv"].is_work);
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
    }
}
