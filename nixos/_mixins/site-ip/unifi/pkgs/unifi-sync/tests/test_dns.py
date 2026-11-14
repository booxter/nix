import ipaddress

import pytest
from unifi_sync import dns


class FakeDnsClient:
    def __init__(self, policies):
        self.policies = {policy["id"]: policy for policy in policies}

    def list_sites(self):
        return [{"id": "site", "internalReference": "default"}]

    def list_dns_policies(self, site_id):
        return list(self.policies.values())

    def create_dns_policy(self, site_id, payload):
        policy = {"id": "new", **payload}
        self.policies["new"] = policy
        return policy

    def update_dns_policy(self, site_id, policy_id, payload):
        assert policy_id in self.policies
        policy = {"id": policy_id, **payload}
        self.policies[policy_id] = policy
        return policy


A_POLICY = {
    "id": "cache",
    "type": "A_RECORD",
    "domain": "cache.ihar.dev",
    "enabled": True,
    "ttlSeconds": 300,
    "ipv4Address": "192.168.16.3",
}
CNAME_POLICY = {
    "id": "cache",
    "type": "CNAME_RECORD",
    "domain": "cache.ihar.dev",
    "enabled": True,
    "ttlSeconds": 300,
    "targetDomain": "beast.home.arpa",
}
A_RECORD = dns.DnsRecordSpec(
    record_type="A_RECORD",
    domain="cache.ihar.dev",
    ttl_seconds=300,
    ipv4_address=ipaddress.IPv4Address("192.168.16.3"),
)
CNAME_RECORD = dns.DnsRecordSpec(
    record_type="CNAME_RECORD",
    domain="cache.ihar.dev",
    ttl_seconds=300,
    target_domain="beast.home.arpa",
)


@pytest.mark.parametrize(
    "original, desired, expected",
    [(A_POLICY, CNAME_RECORD, CNAME_POLICY), (CNAME_POLICY, A_RECORD, A_POLICY)],
)
def test_record_type_migration_preserves_identity_and_is_idempotent(original, desired, expected):
    client = FakeDnsClient([original])

    preview = dns.sync_records(client, "default", [desired], dry_run=True)
    assert preview["results"][0]["action"] == "update"
    assert preview["results"][0]["changes"]["type"] == {
        "current": original["type"],
        "desired": desired.record_type,
    }
    assert client.policies == {"cache": original}

    result = dns.sync_records(client, "default", [desired], dry_run=False)
    assert result["changed_count"] == 1
    assert client.policies == {"cache": expected}

    repeated = dns.sync_records(client, "default", [desired], dry_run=False)
    assert repeated["changed_count"] == 0
    assert client.policies == {"cache": expected}


def test_conflicting_host_policies_are_rejected_without_changes():
    policies = [A_POLICY, {**CNAME_POLICY, "id": "alias"}]
    client = FakeDnsClient(policies)

    with pytest.raises(dns.UnifiError, match="multiple UniFi DNS policies"):
        dns.sync_records(client, "default", [CNAME_RECORD], dry_run=False)

    assert list(client.policies.values()) == policies
