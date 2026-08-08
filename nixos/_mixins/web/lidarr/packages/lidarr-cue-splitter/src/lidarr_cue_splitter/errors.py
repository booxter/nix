class CueSplitterError(RuntimeError):
    pass


class NeedsAttention(CueSplitterError):
    pass


class ManualMatchRequired(NeedsAttention):
    pass


class SourceInvalid(CueSplitterError):
    pass
