from attention_inbox.model import InboxItem


def reason_label(reason: str) -> str:
    labels = {
        "approval_required": "Approval required",
        "assigned": "Assigned",
        "build_failed": "Build failed",
        "directly_addressed": "Directly addressed",
        "marked": "Marked",
        "member_access_requested": "Member access requested",
        "mentioned": "Mentioned",
        "merge_train_removed": "Removed from merge train",
        "unmergeable": "Unmergeable",
    }
    return labels.get(reason, reason.replace("_", " ").capitalize())


def render_text(items: list[InboxItem]) -> str:
    if not items:
        return "No pending items.\n"
    noun = "item" if len(items) == 1 else "items"
    lines = [f"{len(items)} pending {noun}:"]
    for item in items:
        location = item.context or ""
        if item.reference:
            location += item.reference
        fields = [
            f"[{item.source}] {reason_label(item.reason)}",
            location or None,
            item.title,
        ]
        lines.append("- " + " · ".join(field for field in fields if field))
        if item.url:
            lines.append(f"  {item.url}")
    return "\n".join(lines) + "\n"
