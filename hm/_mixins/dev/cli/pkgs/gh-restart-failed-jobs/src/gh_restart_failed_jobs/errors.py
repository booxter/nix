class RestartError(Exception):
    """Expected failure while finding or restarting workflow runs."""


class UsageError(RestartError):
    """Invalid command-line input."""
