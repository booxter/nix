import argparse
import os
import re
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Final, Never, TextIO
from urllib.parse import urlparse

from gh_restart_failed_jobs.api import GitHubApi, PyGithubApi
from gh_restart_failed_jobs.auth import GhTokenProvider, SubprocessRunner
from gh_restart_failed_jobs.errors import RestartError, UsageError
from gh_restart_failed_jobs.model import PullRequest, RepositoryRef

DEFAULT_HOST: Final = "github.com"
PULL_PATH: Final = re.compile(r"^/([^/]+)/([^/]+)/pull/([0-9]+)(?:/.*)?$")


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        raise UsageError(message)


def parser() -> ArgumentParser:
    result = ArgumentParser(
        prog="gh-restart-failed-jobs",
        description=(
            "Restart failed GitHub Actions jobs in every workflow run for a pull request. "
            "With --all, confirm and process all open pull requests in repositories owned "
            "by the authenticated GitHub user."
        ),
    )
    result.add_argument("--all", action="store_true", dest="all_pull_requests")
    result.add_argument("targets", nargs="*")
    return result


def pull_request_from_url(value: str) -> PullRequest:
    parsed = urlparse(value)
    match = PULL_PATH.fullmatch(parsed.path)
    if parsed.scheme != "https" or not parsed.netloc or match is None:
        raise UsageError(f"not a GitHub pull request URL: {value}")
    owner, repository, number = match.groups()
    reference = RepositoryRef(parsed.netloc, f"{owner}/{repository}")
    return PullRequest(
        reference,
        int(number),
        url=f"https://{reference.host}/{reference.name_with_owner}/pull/{number}",
    )


@dataclass
class Application:
    api: GitHubApi
    stdin: TextIO
    stdout: TextIO
    stderr: TextIO

    def restart(self, pull_request: PullRequest) -> int:
        try:
            run_ids = self.api.failed_actions_run_ids(pull_request)
            if not run_ids:
                self._write(f"{pull_request.label}: no failed GitHub Actions jobs found")
                return 0
            for run_id in run_ids:
                self._write(
                    f"{pull_request.label}: restarting failed jobs in workflow run {run_id}"
                )
                self.api.rerun_failed_jobs(pull_request, run_id)
        except RestartError as error:
            print(f"gh-restart-failed-jobs: {pull_request.label}: {error}", file=self.stderr)
            return 1

        self._write(
            f"{pull_request.label}: restarted failed jobs in {len(run_ids)} workflow run(s)"
        )
        return 0

    def process_all(self, host: str) -> int:
        try:
            owner = self.api.authenticated_login(host)
            pull_requests = self.api.open_pull_requests(host, owner)
        except RestartError as error:
            print(f"gh-restart-failed-jobs: {error}", file=self.stderr)
            return 1

        count = len(pull_requests)
        if count == 0:
            self._write(f"no open pull requests found for {owner}")
            return 0

        self._write(f"found {count} open pull request(s) for {owner}:")
        for index, pull_request in enumerate(pull_requests, start=1):
            print(
                f"  {index}. {pull_request.label} {pull_request.title}\n     {pull_request.url}",
                file=self.stdout,
            )

        print(f"Process all {count} open pull request(s)? [y/N] ", end="", file=self.stderr)
        if self.stdin.readline().strip().lower() not in {"y", "yes"}:
            self._write("cancelled")
            return 0

        failed = 0
        for index, pull_request in enumerate(pull_requests, start=1):
            self._write(f"[{index}/{count}] processing {pull_request.label}: {pull_request.title}")
            self._write(f"[{index}/{count}] {pull_request.url}")
            if self.restart(pull_request) != 0:
                failed += 1
                print(
                    f"gh-restart-failed-jobs: [{index}/{count}] {pull_request.label} failed",
                    file=self.stderr,
                )

        self._write(
            f"processed {count} pull request(s): {count - failed} succeeded, {failed} failed"
        )
        return 1 if failed else 0

    def _write(self, message: str) -> None:
        print(f"gh-restart-failed-jobs: {message}", file=self.stdout)


def main(
    argv: Sequence[str] | None = None,
    *,
    api: GitHubApi | None = None,
    environ: Mapping[str, str] | None = None,
    stdin: TextIO = sys.stdin,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    argument_parser = parser()
    try:
        arguments = argument_parser.parse_args(argv)
        if arguments.all_pull_requests:
            if arguments.targets:
                raise UsageError("--all does not accept pull request arguments")
        elif len(arguments.targets) not in {1, 2}:
            raise UsageError("expected a pull request URL or repository and number")
    except UsageError as error:
        print(f"gh-restart-failed-jobs: {error}", file=stderr)
        argument_parser.print_usage(stderr)
        return 2

    github = api or PyGithubApi(
        GhTokenProvider(
            environ=os.environ if environ is None else environ,
            runner=SubprocessRunner(),
            executable="gh",
        )
    )
    application = Application(github, stdin, stdout, stderr)
    if arguments.all_pull_requests:
        return application.process_all(DEFAULT_HOST)

    try:
        if len(arguments.targets) == 1:
            pull_request = pull_request_from_url(arguments.targets[0])
        else:
            repository, number_text = arguments.targets
            if not number_text.isdigit():
                raise UsageError(f"not a pull request number: {number_text}")
            if repository.count("/") == 0:
                repository = f"{github.authenticated_login(DEFAULT_HOST)}/{repository}"
            elif repository.count("/") != 1:
                raise UsageError(f"not a repository name: {repository}")
            pull_request = PullRequest(
                RepositoryRef(DEFAULT_HOST, repository),
                int(number_text),
            )
    except UsageError as error:
        print(f"gh-restart-failed-jobs: {error}", file=stderr)
        argument_parser.print_usage(stderr)
        return 2
    except RestartError as error:
        print(f"gh-restart-failed-jobs: {error}", file=stderr)
        return 1
    return application.restart(pull_request)
