class HomeAssistantError(RuntimeError):
    """Expected operator-facing failure."""


class HomeAssistantUnavailable(HomeAssistantError):
    """Home Assistant could not serve an HTTP request."""
