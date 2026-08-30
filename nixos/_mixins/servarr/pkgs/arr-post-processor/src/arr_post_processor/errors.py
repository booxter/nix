class PostProcessorError(RuntimeError):
    pass


class NeedsAttention(PostProcessorError):
    pass


class ManualMatchRequired(NeedsAttention):
    pass


class SourceInvalid(PostProcessorError):
    pass
