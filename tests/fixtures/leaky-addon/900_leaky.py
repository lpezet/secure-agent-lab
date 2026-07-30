"""Deliberately vulnerable addon. The positive control for 35-audit-leak.

This is what PLAYBOOK.md recommended for Telegram from 1.2.0 to 1.4.1. It is
here so the leak scan has something it must catch: a scan that only ever runs
against correct addons passes whether or not it works, and "the trail
contained no secret" is also what you get from a trail that was never written.

NOT a template, and not a candidate for fixing. It lives under tests/fixtures/
so 00-config-lint.test.sh's globs (stack/proxy/addons, examples/*/proxy) do not
reach it — if those are ever broadened to **/*.py, exclude this path rather
than repairing the file.
"""
import audit
from mitmproxy import http


def request(flow: http.HTTPFlow) -> None:
    if flow.request.host != "api.telegram.org":
        return

    # Anti-pattern 1: the raw path, query string and all.
    audit.log_event("raw_path", provider="telegram", path=flow.request.path)

    # Anti-pattern 2: the parse that reads as safe. flow.request.path carries
    # the query string, so splitting on "/" alone leaves it inside the last
    # segment. The token sits in segment 1 and stays out — which is exactly
    # why this looked like the careful version of anti-pattern 1.
    api_method = flow.request.path.split("/")[2]
    audit.log_event("naive_split", provider="telegram", api_method=api_method)
