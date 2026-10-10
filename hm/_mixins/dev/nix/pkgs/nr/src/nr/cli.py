import argparse
import os
from collections.abc import Mapping, Sequence

from nr.review import NixpkgsReviewExecutor, ReviewExecutor, ReviewRequest, resolve_review


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nr",
        description="Review a nixpkgs pull request using the fleet's remote builders.",
    )
    parser.add_argument("-p", "--post-result", action="store_true")
    parser.add_argument("-a", "--approve", action="store_true")
    parser.add_argument("-t", "--tests", action="store_true")
    parser.add_argument("-i", "--include-pr", action="append", default=[])
    parser.add_argument("-s", "--systems")
    parser.add_argument("-C", "--cuda", action="store_true")
    parser.add_argument("-l", "--local", action="store_true", help="exclude community builders")
    parser.add_argument("pull_requests", nargs="+")
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    environment: Mapping[str, str] | None = None,
    executor: ReviewExecutor | None = None,
) -> int:
    arguments = _parser().parse_args(argv)
    environ = os.environ if environment is None else environment
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
    return (executor or NixpkgsReviewExecutor()).run(resolve_review(request, environ))
