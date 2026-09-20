"""Google search through SerpBase. The logic is taken from the prime-agent skill.

The key comes from the environment only: the hand holds a MASK, and the real key
is pasted in by the egress filter for api.serpbase.dev. The agent itself does
not set the key up.

It is run as a plain file, not imported:

    python /skills/websearch/search.py "query" [--num 5] [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import httpx

API_URL = "https://api.serpbase.dev/google/search"


def search(query: str, num_results: int = 5, timeout: int = 45) -> dict:
    """A single request to SerpBase. Returns the parsed response whole."""
    api_key = os.environ.get("SERPBASE_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError(
            "web search is not configured: no SerpBase key. The key is set by the "
            "owner in the stack .env (SWEET_SERPBASE_API_KEY and "
            "SWEET_SERPBASE_API_KEY_MASK), and the agent cannot set it up itself "
            "— tell the human about it"
        )

    resp = httpx.post(
        API_URL,
        json={"q": query},
        headers={"X-API-Key": api_key, "Content-Type": "application/json"},
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json()


def format_results(data: dict, query: str, num_results: int = 5) -> str:
    """The SerpBase response as readable text: snippet, results, news, PAA."""
    sections: list[str] = []

    featured = data.get("featured_snippet")
    if isinstance(featured, dict):
        lines = [str(featured.get(k) or "").strip() for k in ("title", "snippet", "link")]
        lines = [l for l in lines if l]
        if lines:
            sections.append("Featured snippet:\n" + "\n".join(lines))

    for i, result in enumerate((data.get("organic") or [])[:num_results]):
        lines = [f"Result {i}: {(result.get('title') or '').strip() or 'Untitled'}"]
        link = (result.get("link") or "").strip()
        if link:
            lines.append(f"URL: {link}")
        snippet = (result.get("snippet") or "").strip()
        if snippet:
            lines.append(snippet)
        sections.append("\n".join(lines))

    stories = []
    for item in (data.get("top_stories") or [])[:3]:
        title = (item.get("title") or "").strip()
        if not title:
            continue
        link = (item.get("link") or "").strip()
        stories.append(f"{title}\n{link}" if link else title)
    if stories:
        sections.append("Top stories:\n" + "\n".join(stories))

    questions = []
    for item in (data.get("people_also_ask") or [])[:3]:
        question = (item.get("question") or "").strip()
        if not question:
            continue
        answer = (item.get("snippet") or "").strip()
        questions.append(f"Q: {question}\nA: {answer}" if answer else f"Q: {question}")
    if questions:
        sections.append("People Also Ask:\n" + "\n".join(questions))

    if not sections:
        return f"No results returned for query: {query}"

    return "\n\n---\n\n".join(sections)


def main() -> int:
    parser = argparse.ArgumentParser(description="Google search through SerpBase")
    parser.add_argument("query", help="the search query")
    parser.add_argument("--num", type=int, default=5, help="how many organic results (5 by default)")
    parser.add_argument("--json", action="store_true", help="the raw API response instead of text")
    args = parser.parse_args()

    try:
        data = search(args.query, num_results=args.num)
    except Exception as e:
        print(f"search failed for \"{args.query}\": {e}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(f'Results for query "{args.query}":\n')
        print(format_results(data, args.query, num_results=args.num))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
