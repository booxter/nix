from prometheus_client import CollectorRegistry, generate_latest
from prometheus_client.parser import text_string_to_metric_families


def samples(registry: CollectorRegistry) -> dict[str, list[tuple[dict[str, str], float]]]:
    return text_samples(generate_latest(registry).decode())


def text_samples(content: str) -> dict[str, list[tuple[dict[str, str], float]]]:
    parsed: dict[str, list[tuple[dict[str, str], float]]] = {}
    for family in text_string_to_metric_families(content):
        for sample in family.samples:
            parsed.setdefault(sample.name, []).append((sample.labels, sample.value))
    return parsed


def value(
    metrics: dict[str, list[tuple[dict[str, str], float]]],
    name: str,
    **expected_labels: str,
) -> float:
    matches = [
        sample_value
        for labels, sample_value in metrics[name]
        if all(labels.get(key) == label for key, label in expected_labels.items())
    ]
    assert len(matches) == 1
    return matches[0]
