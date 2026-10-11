import argparse
import os
import sys
from collections.abc import Mapping, Sequence

from nr.process import ProcessRunner
from nr.remote import (
    RemoteAttacher,
    RemoteSubmitter,
    SshAttacher,
    SshSubmitter,
    attach_command,
    validate_host,
)
from nr.review import NixpkgsReviewExecutor, ReviewExecutor, ReviewRequest, resolve_review


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nr",
        description="Review a nixpkgs pull request using the fleet's remote builders.",
        epilog=(
            "Remote mode returns after submission. Each invocation gets a window in session nr; "
            "finished windows retain the exit status. The destination needs nr and a nixpkgs "
            "checkout at ~/src/nixpkgs (override there with NR_REVIEW_DIRECTORY). "
            "NR_REMOTE_HOST overrides the default destination. "
            "Arguments after -- are passed to nixpkgs-review, e.g. nr 123 -- -p hello. "
            "Pass Nix build options with --build-args='--cores 2'; they are merged with "
            "fleet defaults. Remote builders use their own cores setting."
        ),
    )
    parser.add_argument("-p", "--post-result", action="store_true")
    parser.add_argument("-a", "--approve", action="store_true")
    parser.add_argument("-t", "--tests", action="store_true")
    parser.add_argument("-i", "--include-pr", action="append", default=[])
    parser.add_argument("-s", "--systems")
    parser.add_argument("-C", "--cuda", action="store_true")
    parser.add_argument(
        "-r", "--remote", action="store_true", help="submit a detached review on the remote host"
    )
    parser.add_argument(
        "--host", help="remote SSH machine name (default: configured host or frame)"
    )
    parser.add_argument(
        "--attach",
        action="store_true",
        help="attach to the existing remote tmux session without submitting a review",
    )
    parser.add_argument("-l", "--local", action="store_true", help="exclude community builders")
    parser.add_argument("pull_requests", nargs="*")
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    environment: Mapping[str, str] | None = None,
    executor: ReviewExecutor | None = None,
    submitter: RemoteSubmitter | None = None,
    attacher: RemoteAttacher | None = None,
) -> int:
    parser = _parser()
    raw_arguments = list(sys.argv[1:] if argv is None else argv)
    separator = raw_arguments.index("--") if "--" in raw_arguments else len(raw_arguments)
    arguments = parser.parse_args(raw_arguments[:separator])
    extra_arguments = tuple(raw_arguments[separator + 1 :])
    if arguments.host is not None and not arguments.remote:
        parser.error("--host requires --remote")
    if arguments.attach and not arguments.remote:
        parser.error("--attach requires --remote")
    if arguments.attach and (arguments.pull_requests or extra_arguments):
        parser.error("--attach cannot be combined with review arguments")
    if not arguments.pull_requests and not arguments.attach:
        parser.error("at least one pull request is required unless --attach is given")
    environ = os.environ if environment is None else environment
    host = arguments.host if arguments.host is not None else environ.get("NR_REMOTE_HOST", "frame")
    try:
        if arguments.remote:
            validate_host(host)
        if arguments.attach:
            return (attacher or SshAttacher()).attach(host)
        request = ReviewRequest(
            pull_requests=tuple(arguments.pull_requests),
            included_pull_requests=tuple(arguments.include_pr),
            extra_arguments=extra_arguments,
            systems=arguments.systems,
            post_result=arguments.post_result,
            approve=arguments.approve,
            tests=arguments.tests,
            cuda=arguments.cuda,
            local=arguments.local,
        )
        if arguments.remote:
            result = (submitter or SshSubmitter(ProcessRunner())).submit(host, request)
            print(f"Submitted to {host}, window nr:{result.window}")
            print(f"Watch: {attach_command(host)}")
            return 0
        return (executor or NixpkgsReviewExecutor()).run(resolve_review(request, environ))
    except KeyboardInterrupt:
        if arguments.remote and not arguments.attach:
            print(
                f"Submission interrupted; check before retrying: {attach_command(host)}",
                file=sys.stderr,
            )
        return 130
    except (OSError, RuntimeError, ValueError) as error:
        print(f"nr: {error}", file=sys.stderr)
        return 1
