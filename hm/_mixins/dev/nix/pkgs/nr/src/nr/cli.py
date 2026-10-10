import argparse
import os
import sys
from collections.abc import Mapping, Sequence

from nr.process import ProcessRunner
from nr.remote import RemoteSubmitter, SshSubmitter, attach_command, validate_host
from nr.review import NixpkgsReviewExecutor, ReviewExecutor, ReviewRequest, resolve_review


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nr",
        description="Review a nixpkgs pull request using the fleet's remote builders.",
        epilog=(
            "Remote mode returns after submission. Each invocation gets a window in session nr; "
            "finished windows retain the exit status. The destination needs nr and a nixpkgs "
            "checkout at ~/src/nixpkgs (override there with NR_REVIEW_DIRECTORY). "
            "NR_REMOTE_HOST overrides the default destination."
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
    parser.add_argument("-l", "--local", action="store_true", help="exclude community builders")
    parser.add_argument("pull_requests", nargs="+")
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    environment: Mapping[str, str] | None = None,
    executor: ReviewExecutor | None = None,
    submitter: RemoteSubmitter | None = None,
) -> int:
    parser = _parser()
    arguments = parser.parse_args(argv)
    if arguments.host is not None and not arguments.remote:
        parser.error("--host requires --remote")
    environ = os.environ if environment is None else environment
    host = arguments.host if arguments.host is not None else environ.get("NR_REMOTE_HOST", "frame")
    try:
        request = ReviewRequest(
            pull_requests=tuple(arguments.pull_requests),
            included_pull_requests=tuple(arguments.include_pr),
            systems=arguments.systems,
            post_result=arguments.post_result,
            approve=arguments.approve,
            tests=arguments.tests,
            cuda=arguments.cuda,
            local=arguments.local,
        )
        if arguments.remote:
            validate_host(host)
            result = (submitter or SshSubmitter(ProcessRunner())).submit(host, request)
            print(f"Submitted to {host}, window nr:{result.window}")
            print(f"Watch: {attach_command(host)}")
            return 0
        return (executor or NixpkgsReviewExecutor()).run(resolve_review(request, environ))
    except KeyboardInterrupt:
        if arguments.remote:
            print(
                f"Submission interrupted; check before retrying: {attach_command(host)}",
                file=sys.stderr,
            )
        return 130
    except (OSError, RuntimeError, ValueError) as error:
        print(f"nr: {error}", file=sys.stderr)
        return 1
