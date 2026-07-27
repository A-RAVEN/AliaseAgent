"""fetch_worker.py — crawl4ai web page fetcher for AliasAgent.

Protocol: reads one JSON line from stdin, writes one JSON line to stdout.
No command-line arguments. All communication is via stdin/stdout JSON.

Input:  {"url": "https://example.com/page"}
Output: {"ok": true, "url": "...", "title": "...", "content": "# Markdown..."}
         or {"ok": false, "error": "..."}
"""

import sys
import os
import json
import asyncio


def _log(msg: str) -> None:
    """Diagnostic logging to stderr — captured by C++ sidecar into sidecar.log."""
    print(f"WORKER: {msg}", file=sys.stderr, flush=True)


# Dump all environment variables for debugging (once per invocation)
_log(f"python={sys.executable} cwd={os.getcwd()}")
for _k, _v in sorted(os.environ.items()):
    _log(f"ENV: {_k}={_v}")

from crawl4ai import AsyncWebCrawler


def _validate_url(url: str) -> str | None:
    """Defense-in-depth URL validation — C++ side does the main SSRF checks."""
    if not url:
        return "URL is empty"
    lower = url.lower()
    if not lower.startswith("http://") and not lower.startswith("https://"):
        return "URL scheme not allowed"
    return None


async def _fetch(url: str) -> dict:
    """Fetch a URL via crawl4ai and return structured result."""
    _log("creating AsyncWebCrawler...")
    async with AsyncWebCrawler() as crawler:
        _log(f"crawler created, fetching {url}")
        result = await crawler.arun(url)
        _log(f"fetch complete, markdown length={len(result.markdown or '')}")
        title = ""
        if result.metadata and result.metadata.get("title"):
            title = result.metadata["title"]
        return {
            "ok": True,
            "url": url,
            "title": title,
            "content": result.markdown or "",
        }


async def main() -> None:
    line = sys.stdin.readline()
    if not line:
        print(json.dumps({"ok": False, "error": "No input received"}), flush=True)
        return

    try:
        req = json.loads(line)
    except json.JSONDecodeError as e:
        print(json.dumps({"ok": False, "error": f"Invalid JSON: {e}"}), flush=True)
        return

    url = req.get("url", "")
    err = _validate_url(url)
    if err:
        print(json.dumps({"ok": False, "error": err}), flush=True)
        return

    try:
        resp = await _fetch(url)
    except Exception as e:
        resp = {"ok": False, "error": f"Fetch failed: {e}"}

    print(json.dumps(resp), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
