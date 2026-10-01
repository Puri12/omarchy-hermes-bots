"""Hold outbound messages for review in the puri.hermes panel.

Every send_message "send" call is escalated to the Hermes approval gate with the recipient and the
text, which the panel shows as a draft card (Send = once, Discard = deny). Nothing is sent until a
person approves; a denial, timeout or gate error blocks the send.
"""

MAX_PREVIEW_CHARS = 4000


def review_outbound(tool_name, args, task_id="", **kwargs):
    if tool_name != "send_message":
        return None
    args = args or {}
    if args.get("action", "send") != "send":
        return None
    target = str(args.get("target") or "(default target)")
    body = str(args.get("message") or "")
    if len(body) > MAX_PREVIEW_CHARS:
        hidden = len(body) - MAX_PREVIEW_CHARS
        body = f"{body[:MAX_PREVIEW_CHARS]}\n[... {hidden} more characters not shown]"
    # The approval request carries no recipient or body fields, so both travel in the message.
    # The panel parses exactly this layout: "To: <target>", a blank line, then the text.
    return {"action": "approve", "message": f"To: {target}\n\n{body}", "rule_key": f"send_message:{target}"}


def register(ctx):
    ctx.register_hook("pre_tool_call", review_outbound)
