#!/usr/bin/env python3
"""
Files the posts of the subreddits Safelight is posted in, to study what does
well there. Nothing is asked of reddit.com: the posts come from Arctic Shift,
a public Reddit archive, through Jason's scraper (Reddit: Subreddits from
Arctic Shift), run here without its window.

    scripts/reddit-research.py fetch [run numbers]   file the posts (all runs, or the ones named)
    scripts/reddit-research.py runs                  list the runs
    scripts/reddit-research.py summary SwiftUI [days]    what sets the best posts apart (kind, flair, title, hour…)
    scripts/reddit-research.py comments SwiftUI [days]   the best comments under the best posts

Posts land in build/reddit/posts/<subreddit>/<post title>/info.json, the full
log in build/reddit/posts/fetch.log. A second run over the same subreddit
files into the same folders and keeps the comments an earlier run read.

JASON_PY names Jason.py when it is not at ~/Apps/Jason/Source/Jason.py.
"""
import ast
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "build" / "reddit" / "posts"
JASON = Path(os.environ.get("JASON_PY") or Path.home() / "Apps/Jason/Source/Jason.py")

# The two small subreddits in full, with comments: how people describe the
# problem. The big ones: the year's top 100 with comments, plus a plain set of
# ordinary posts to compare the winners against.
RUNS = [
    dict(names="ScreenSensitive eyestrain", sort="new", period="all", max_posts=0, want_comments=True),
    dict(names="SwiftUI coolgithubprojects", sort="top", period="year", max_posts=100, want_comments=True),
    dict(names="SwiftUI", sort="new", period="year", max_posts=0, want_comments=False),
    dict(names="coolgithubprojects", sort="new", period="all", max_posts=1000, want_comments=False),
    dict(names="SideProject", sort="new", period="all", max_posts=1000, want_comments=False),
    dict(names="SideProject", sort="top", period="year", max_posts=100, want_comments=True),
]


def describe(run):
    how = f"{run['sort']}, {run['period']}, " + (f"{run['max_posts']} posts" if run["max_posts"] else "all posts")
    return f"{run['names']}: {how}" + (", with comments" if run["want_comments"] else "")


def load_scraper():
    """Jason's scraper function and its name parser, taken out of Jason.py by
    name, so the app's window code is never run."""
    wanted = {"run_archive_reddit_subreddits", "_parse_reddit_names"}
    tree = ast.parse(JASON.read_text(encoding="utf-8"))
    picked = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in wanted]
    if {node.name for node in picked} != wanted:
        sys.exit(f"{JASON} has no Arctic Shift scraper (looked for {', '.join(sorted(wanted))}).")
    space = {"_set_folder_icon": lambda *a, **k: None}    # no pictures are fetched, so no folder icons
    exec(compile(ast.Module(body=picked, type_ignores=[]), str(JASON), "exec"), space)
    return space["run_archive_reddit_subreddits"]


def fetch(numbers):
    import threading
    import time
    scrape = load_scraper()
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "fetch.log", "a", encoding="utf-8") as log:
        lock = threading.Lock()     # the scraper logs from several threads

        def say(line):
            with lock:
                log.write(str(line) + "\n")
                log.flush()
                # The window's log names every post; here only the outcomes
                if any(mark in str(line) for mark in ("🚀", "📋", "✅", "⏳", "⚠️", "❌", "🏆")):
                    print(str(line).strip(), flush=True)
        for n in numbers:
            run = RUNS[n - 1]
            print(f"\n[{n}] {describe(run)}", flush=True)
            began = time.monotonic()
            scrape(str(OUT), say, run["names"], want_images=False, all_posts=True,
                   want_comments=run["want_comments"], only_new=False, sort=run["sort"],
                   period=run["period"], max_posts=run["max_posts"])
            say(f"⏱️ [{n}] took {(time.monotonic() - began) / 60:.1f} min")
            print(f"[{n}] took {(time.monotonic() - began) / 60:.1f} min", flush=True)


def load_posts(subreddit, period_days=None):
    """The filed posts of one subreddit, each once, old enough (3 days) for
    the archive to have read their score a second time."""
    import json
    import time
    from datetime import datetime, timezone
    posts, now = {}, time.time()
    for info in (OUT / subreddit).glob("*/info.json"):
        try: d = json.loads(info.read_text(encoding="utf-8"))
        except Exception: continue
        raw = d.get("raw") or {}
        try: when = datetime.strptime(d["created"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except Exception: continue
        age = (now - when.timestamp()) / 86400
        if age < 3 or (period_days and age > period_days): continue
        link = d.get("link") or ""
        host = (raw.get("domain") or "").lower()
        if raw.get("is_self"): kind = "text"
        elif raw.get("is_video") or host == "v.redd.it": kind = "video"
        elif "/gallery/" in link: kind = "gallery"
        elif raw.get("post_hint") == "image" or host == "i.redd.it": kind = "image"
        elif "youtu" in host: kind = "youtube"
        elif "github" in host: kind = "github link"
        else: kind = "other link"
        text = d.get("text") or ""
        if kind == "text" and ("preview.redd.it" in text or "i.redd.it" in text): kind = "text + picture"
        if kind == "text" and "v.redd.it" in text: kind = "text + video"
        posts[d["id"]] = dict(title=d.get("title") or "", score=d.get("score") or 0, comments=d.get("num_comments") or 0,
                              ratio=d.get("upvote_ratio"), flair=d.get("flair") or "(none)", kind=kind, text=text,
                              when=when, removed=raw.get("removed_by_category"), url=d.get("url"),
                              tree=d.get("comments") or [])
    return list(posts.values())


def summary(subreddit, period_days=None, top_share=0.1):
    """What sets the best-scored posts of a subreddit apart from the rest."""
    import re
    from statistics import median
    posts = load_posts(subreddit, period_days)
    if not posts:
        print(f"r/{subreddit}: nothing filed"); return
    posts.sort(key=lambda p: p["score"], reverse=True)
    n_top = max(1, int(len(posts) * top_share))
    top, scores = posts[:n_top], sorted(p["score"] for p in posts)
    pick = lambda q: scores[min(len(scores) - 1, int(q * len(scores)))]
    print(f"\n===== r/{subreddit}: {len(posts)} posts, {min(p['when'] for p in posts):%Y-%m-%d} to {max(p['when'] for p in posts):%Y-%m-%d}")
    print(f"score: median {pick(.5)}, 75% {pick(.75)}, 90% {pick(.9)}, 99% {pick(.99)}, best {scores[-1]}"
          f" · top group = best {n_top} (score {top[-1]['score']}+)")

    def table(name, key, least=5):
        groups = {}
        for p in posts: groups.setdefault(key(p), []).append(p)
        print(f"\n{name:<28}{'posts':>6}{'share':>7}{'of top':>8}{'median':>8}{'comments':>9}")
        for label, group in sorted(groups.items(), key=lambda g: -len(g[1])):
            if len(group) < least: continue
            in_top = sum(1 for p in group if p in top)
            print(f"{str(label)[:27]:<28}{len(group):>6}{len(group) / len(posts):>7.0%}{in_top / n_top:>8.0%}"
                  f"{median(p['score'] for p in group):>8.0f}{median(p['comments'] for p in group):>9.0f}")

    def bucket(value, edges):
        low = 0
        for edge in edges:
            if value < edge: return f"{low}–{edge - 1}"
            low = edge
        return f"{low}+"

    table("kind", lambda p: p["kind"])
    table("flair", lambda p: p["flair"])
    table("title length (characters)", lambda p: bucket(len(p["title"]), (30, 50, 70, 100, 150)))
    table("body length (words)", lambda p: bucket(len(p["text"].split()), (1, 50, 150, 300, 600)))
    table("weekday (UTC)", lambda p: p["when"].strftime("%a"))
    table("hour (UTC)", lambda p: bucket(p["when"].hour, (4, 8, 12, 16, 20)))
    words = [("I made / I built", r"\bI(?:'ve| have)? (?:made|built|created|wrote)\b|\bmy (?:first|new)?\s*(?:app|project|library|package)\b"),
             ("open source", r"open[- ]?source|\bOSS\b|github"),
             ("mentions AI", r"\bAI\b|\bLLM|claude|chatgpt|\bGPT|copilot|vibe[- ]?cod|cursor\b"),
             ("says built with AI", r"(?:built|made|written|coded|generated) (?:\w+ ){0,3}(?:with|by|using) (?:\w+ ){0,2}(?:AI|claude|chatgpt|cursor|copilot)|vibe[- ]?cod"),
             ("question (title has ?)", r"\?"),
             ("macOS / Mac", r"\bmac\s?os\b|\bmac\b|menu ?bar"),
             ("free", r"\bfree\b")]
    print(f"\n{'title or body says':<28}{'posts':>6}{'share':>7}{'of top':>8}{'median':>8}{'comments':>9}")
    for label, pattern in words:
        where = (lambda p: p["title"]) if "title has" in label else (lambda p: p["title"] + "\n" + p["text"])
        group = [p for p in posts if re.search(pattern, where(p), re.I)]
        if not group: continue
        in_top = sum(1 for p in group if p in top)
        print(f"{label:<28}{len(group):>6}{len(group) / len(posts):>7.0%}{in_top / n_top:>8.0%}"
              f"{median(p['score'] for p in group):>8.0f}{median(p['comments'] for p in group):>9.0f}")
    gone = [p for p in posts if p["removed"]]
    print(f"\nremoved later: {len(gone)} of {len(posts)} ({len(gone) / len(posts):.0%})"
          + ("; by " + ", ".join(f"{k} {sum(1 for p in gone if p['removed'] == k)}" for k in sorted({p['removed'] for p in gone})) if gone else ""))
    print("\nbest 25:")
    for p in posts[:25]:
        print(f"{p['score']:>6} {p['comments']:>4}c  {p['kind']:<14} [{p['flair'][:14]}] {p['title'][:110]}")


def best_comments(subreddit, period_days=None, posts_wanted=15, per_post=3):
    """The best-scored comments under the best posts: how readers answered."""
    posts = sorted(load_posts(subreddit, period_days), key=lambda p: p["score"], reverse=True)
    for p in [p for p in posts if p["tree"]][:posts_wanted]:
        print(f"\n## {p['score']} · {p['kind']} · {p['title'][:120]}")
        first = sorted((c for c in p["tree"] if c.get("body") and not c.get("stickied")), key=lambda c: -(c.get("score") or 0))
        for c in first[:per_post]:
            print(f"   {c.get('score') or 0:>4}  " + " ".join(c["body"].split())[:300])


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] in (["summary"], ["comments"]) and len(args) >= 2:
        days = int(args[2]) if len(args) > 2 else None
        (summary if args[0] == "summary" else best_comments)(args[1], days)
    elif args[:1] == ["runs"]:
        for i, run in enumerate(RUNS, 1):
            print(f"{i}. {describe(run)}")
    elif args[:1] == ["fetch"]:
        fetch([int(a) for a in args[1:]] or range(1, len(RUNS) + 1))
    else:
        sys.exit(__doc__.strip())
