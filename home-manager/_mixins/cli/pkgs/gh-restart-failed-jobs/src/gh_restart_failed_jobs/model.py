from dataclasses import dataclass


@dataclass(frozen=True)
class RepositoryRef:
    host: str
    name_with_owner: str


@dataclass(frozen=True)
class PullRequest:
    repository: RepositoryRef
    number: int
    title: str = ""
    url: str = ""

    @property
    def label(self) -> str:
        return f"{self.repository.name_with_owner}#{self.number}"


@dataclass(frozen=True)
class CheckRun:
    conclusion: str | None
    details_url: str | None
