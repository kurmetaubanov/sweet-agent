"""Fetch a page and hand it back as markdown.

Parsing the markup with selectors is expensive and usually pointless: picking
`.showbox` -> `#ShowtimesList` -> `.ShowtimesContainer` takes dozens of calls,
and every printed chunk of HTML is then re-read on every following step.
Markdown puts the right things next to each other by itself — the heading, the
label and the values come in a row, as on the screen.

    python /skills/webpage/page.py <url>                    the whole page
    python /skills/webpage/page.py <url> --find "\\d+:\\d+"  chunks around the matches
    python /skills/webpage/page.py <url> --tables           tables through pandas
    python /skills/webpage/page.py <url> --from "Now" --to "Coming"   the chunk between two markers
"""

from __future__ import annotations

import argparse
import re
import sys

import httpx
import markdownify

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"


def fetch(url: str, timeout: int = 30) -> str:
    r = httpx.get(url, headers={"User-Agent": UA}, timeout=timeout, follow_redirects=True)
    r.raise_for_status()
    return r.text


def to_markdown(html: str) -> str:
    md = markdownify.markdownify(html, strip=["script", "style", "img", "svg", "noscript"])
    # Runs of blank lines are normal after the conversion; they are expensive
    # and mean nothing.
    md = re.sub(r"\n{3,}", "\n\n", md)
    return "\n".join(l.rstrip() for l in md.split("\n")).strip()


def between(text: str, start: str | None, end: str | None) -> str:
    """The chunk between two markers — so the whole page does not have to be dragged in."""
    lo = 0 if not start else text.find(start)
    if lo == -1:
        return f"marker {start!r} not found on the page"
    hi = len(text) if not end else text.find(end, lo + 1)
    return text[lo : hi if hi != -1 else len(text)]


def find(text: str, pattern: str, around: int = 200, limit: int = 30) -> str:
    """Chunks around the matches; ranges that touch are glued together."""
    spans = []
    for m in list(re.finditer(pattern, text))[:limit]:
        lo, hi = max(0, m.start() - around), min(len(text), m.end() + around)
        if spans and lo <= spans[-1][1]:
            spans[-1] = (spans[-1][0], hi)
        else:
            spans.append((lo, hi))
    if not spans:
        return f"nothing matched {pattern!r}"
    return "\n\n---\n\n".join(text[lo:hi] for lo, hi in spans)


def tables(html: str, limit: int = 5) -> str:
    try:
        import pandas as pd
    except ImportError:
        return "pandas is not available"

    try:
        frames = pd.read_html(html)
    except ValueError:
        return "no tables found"

    out = []
    for i, df in enumerate(frames[:limit]):
        out.append(f"--- table {i}: {df.shape[0]}x{df.shape[1]}")
        out.append(df.head(20).to_string())
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="A page as markdown")
    parser.add_argument("url")
    parser.add_argument("--find", metavar="REGEX", help="chunks around the matches")
    parser.add_argument("--tables", action="store_true", help="tables through pandas")
    parser.add_argument("--from", dest="start", metavar="TEXT", help="start at this marker")
    parser.add_argument("--to", dest="end", metavar="TEXT", help="end at this marker")
    parser.add_argument("--max", type=int, default=6000, help="output ceiling in characters")
    args = parser.parse_args()

    try:
        html = fetch(args.url)
    except Exception as e:
        print(f"could not fetch {args.url}: {e}", file=sys.stderr)
        return 1

    if args.tables:
        result = tables(html)
    else:
        md = to_markdown(html)
        if args.start or args.end:
            md = between(md, args.start, args.end)
        result = find(md, args.find) if args.find else md

    if len(result) > args.max:
        result = (
            result[: args.max]
            + f"\n... [cut, {len(result)} characters in total;"
            + " take the part you need with --find or --from/--to]"
        )

    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
