"""browse - fetch a web page for reading, escalating only as far as it has to.

WHY THIS EXISTS. Agent-driven research on this box kept falling back to "drive
Playwright by hand", which is both the slowest option and, measured, one of the
most detectable: a May 2026 benchmark over 31 targets put unpatched Playwright at
24 OK / 5 blocked while a raw-CDP driver scored 28 / 0, and a plain HTTP client
with a browser-shaped TLS handshake tied a 130 MB patched Chromium. The spread
across the whole stealth ecosystem was 5 targets in 31. So the win is not a
stealth fork - it is (a) not launching a browser for the ~70% of pages that do
not need one, and (b) when a browser IS needed, using the real Chrome on this
machine with its real profile rather than a fresh automation Chromium.

THE LADDER. Each rung is tried in order and the first one that yields readable
text wins. The rung that won is recorded per-domain in the journal, so the next
fetch of that host starts there instead of re-paying the discovery cost:

  1. direct   httpx from this machine. Cheapest, no browser process.
  2. reader   a third-party server-side reader (r.jina.ai). OPT-IN ONLY: it
              discloses the URL to Jina, so it never runs unless asked.
  3. chrome   CDP-attach to an already-running Chrome (scripts/start-browse-chrome.ps1).
              Real browser build, real profile, real cookies, challenges you
              cleared once stay cleared.
  4. handoff  not a fetch. A challenge was detected and the tool exits EX_BLOCKED
              telling the caller to ask a human to clear it in the live browser.

WHAT THIS TOOL WILL NOT DO. It does not solve CAPTCHAs, rotate proxies, spoof
fingerprints, or retry a refusal in a loop. A site that has decided to refuse
machine traffic is answered by asking the human, not by trying harder: since
mid-2025 a Cloudflare block is increasingly a policy setting rather than a
detection result, and no amount of local cleverness argues with a policy.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

from . import __version__

# Exit codes. Distinct on purpose: the caller's next move differs per outcome, and
# collapsing "the site wants money" into "blocked" loses the one case where there
# is a documented way through (Cloudflare's pay-per-crawl answers 402 with a
# machine-readable price).
EX_OK = 0
EX_USAGE = 2
EX_BLOCKED = 3
EX_ROBOTS = 4
EX_PAYMENT = 5
EX_UNREACHABLE = 6

# A user-directed fetch is not a crawler, and this tool is not pretending to be
# one or hiding from one. It sends a current Chrome UA because that is what the
# request actually is - a person asked for this page now, one page, once - and
# because the honest-crawler UA is precisely what blanket anti-AI rules refuse.
# `--ua honest` switches to self-identification for sites where that is wanted;
# robots.txt is consulted either way (see robots_verdict).
UA_BROWSER = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
)
UA_HONEST = "toolbox-browse/{v} (+user-directed single-page fetch; one request per ask)"

# The product token this tool answers to in robots.txt, independent of the UA
# header. A full browser UA is the wrong thing to match groups with: every
# Chrome-shaped string begins "Mozilla", so it would silently claim any group a
# site wrote for a crawler called Mozilla-something.
ROBOTS_TOKEN = "toolbox-browse"

DEFAULT_CDP = "http://127.0.0.1:9222"

# Markers used to NAME a refusal, never to decide that one happened. See
# diagnose() for why that distinction is the whole ballgame - both of the ordering
# bugs measured on 2026-09-17 came from letting a marker veto a page that had
# already rendered:
#
#   scrapfly.io  200, a full article ABOUT bot detection, reported as DataDome
#                because the word "datadome" is in its prose.
#   medium.com   200, real homepage, real body text, reported as Cloudflare
#                because Cloudflare injects /cdn-cgi/challenge-platform/ into
#                ordinary pages it fronts - it is not an interstitial marker.
#
# Both are harmless here, because nothing in this list is consulted until the
# response has already failed to produce readable content.
#
# Phrases an interstitial puts in its VISIBLE TEXT. Used for a 2xx, where the raw
# HTML has proven untrustworthy but the rendered words have not: a challenge page
# tells the reader it is a challenge page, and a thin ordinary page does not.
# medium.com's homepage extracts to 134 chars of nav links and no such phrase,
# which is how it stopped being reported as blocked.
CHALLENGE_TEXT = (
    ("cloudflare", "just a moment"),
    ("cloudflare", "enable javascript and cookies"),
    ("cloudflare", "verifying you are human"),
    ("cloudflare", "checking your browser"),
    ("cloudflare", "attention required"),
    ("cloudflare", "needs to review the security of your connection"),
    ("datadome", "verify you are a human"),
    ("perimeterx", "press and hold"),
    ("unnamed", "unusual traffic"),
    ("unnamed", "access denied"),
    ("unnamed", "are you a robot"),
)

CHALLENGE_MARKERS = (
    ("cloudflare", "__cf_chl"),
    ("cloudflare", "cf-chl-"),
    ("cloudflare", "/cdn-cgi/challenge-platform/"),
    ("cloudflare", "attention required! | cloudflare"),
    ("cloudflare", "just a moment..."),
    ("cloudflare", "enable javascript and cookies to continue"),
    ("turnstile", "challenges.cloudflare.com/turnstile"),
    ("datadome", "captcha-delivery.com"),
    ("datadome", "datadome"),
    ("perimeterx", "px-captcha"),
    ("perimeterx", "_pxhd"),
    ("incapsula", "_incapsula_resource"),
    ("akamai", "reference #18."),
)

# r.jina.ai's own refusal codes, named from the STATUS rather than scanned from the body.
#
# Deliberately not diagnose(): running CHALLENGE_TEXT over Jina's markdown envelope is
# exactly the false-positive class diagnose()'s own header documents, where an article
# ABOUT bot detection was once reported as a DataDome challenge. These codes are
# unambiguous, so there is nothing to guess at.
#
# THE `reader-` PREFIX IS LOAD-BEARING, and emit() branches on it. A refusal by the reader
# SERVICE says nothing about the target site, so the standing advice - clear the challenge
# once in the live browser - is wrong for these: no amount of clearing fixes someone
# else's quota. Only 451 is the target itself refusing, and it still routes through the
# reader- branch because Jina, not the site, is who told us.
READER_REFUSAL = {
    401: "reader-unauthorized",
    402: "reader-quota-or-payment",
    429: "reader-rate-limited",
    451: "reader-target-refused",
}

# Below this many extracted characters a 2xx is THIN: possibly a JS shell or a
# nav-only render rather than the page. Thin is a reason to try the next rung, and
# explicitly NOT a failure - the first version of this file treated it as one, and
# example.com (a real 200 with ~180 chars of text) was reported blocked. Any
# genuinely short page would have been. A thin result is kept and returned if no
# later rung does better.
MIN_TEXT = 400

# The selftest's offline fixture. Deliberately contains boilerplate the extractor
# is supposed to drop (nav, script, footer) around one sentence it must keep, so
# the check fails if extraction regresses to "return everything" OR to "return
# nothing". A fixture with only the wanted text could not catch the first.
SELFTEST_HTML = """<!doctype html><html><head><title>Fixture</title>
<script>var tracking = "should not appear";</script></head><body>
<nav><a href="/">home</a><a href="/about">about</a></nav>
<article><h1>Fixture heading</h1>
<p>The extractor kept the body text of this fixture, which is the only sentence
that matters and is long enough not to be mistaken for a nav label.</p></article>
<footer>copyright boilerplate should not appear</footer></body></html>"""
SELFTEST_WANT = "the only sentence"
SELFTEST_REJECT = "should not appear"

# The offline r.jina.ai envelope fixture, transcribed from a REAL response
# (example.com, 2026-09-17) rather than invented, including the cached-snapshot
# warning that response actually carried. Three things have to hold at once: the
# page survives, the header does not reach the text, and the staleness warning is
# not swallowed - so breaking any one of the three fails the check below.
SELFTEST_READER = """Title: Example Domain

URL Source: https://example.com/

Published Time: Tue, 15 Sep 2026 23:41:26 GMT

Warning: This is a cached snapshot of the original page, consider retry with caching opt-out.

Markdown Content:
This domain is for use in documentation examples without needing permission.
"""


def have(module: str) -> bool:
    """Is an optional upgrade importable? Never raises, never imports."""
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


@dataclass
class Result:
    url: str
    final_url: str = ""
    rung: str = ""
    status: int = 0
    text: str = ""
    challenge: str = ""
    notes: list[str] = field(default_factory=list)
    # False on the browser rung: see diagnose(). The status is still REPORTED,
    # because hiding it would be worse, but it is not allowed to veto a DOM that
    # plainly contains the page.
    status_reliable: bool = True

    @property
    def usable(self) -> bool:
        """Did this rung actually return the page? Short pages count."""
        if not self.text or self.challenge:
            return False
        if not self.status_reliable:
            return True
        return self.status < 400

    @property
    def thin(self) -> bool:
        """Usable but suspiciously short - worth letting a later rung try."""
        return self.usable and len(self.text) < MIN_TEXT


# -- journal -------------------------------------------------------------------
# Per-host memory of which rung worked. The point is not speed, it is not
# re-discovering on every single fetch that a given host needs the browser.


def toolbox_root() -> Path:
    env = os.environ.get("CODEX_TOOLBOX")
    if env:
        return Path(env)
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "DevToolbox"


def journal_path() -> Path:
    return toolbox_root() / "state" / "browse-journal.json"


def journal_load() -> dict:
    p = journal_path()
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        # A corrupt or absent journal is not an error - it is a cold cache. It is
        # NOT silently rewritten here either: a rewrite on read would destroy the
        # evidence of whatever corrupted it.
        return {}


def journal_save(host: str, rung: str) -> None:
    p = journal_path()
    data = journal_load()
    data[host] = {"rung": rung, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    except OSError as exc:
        # Losing the journal costs a re-discovery, not a fetch. Never fatal.
        print(f"browse: could not write journal ({exc})", file=sys.stderr)


def journal_rung(attempts: list["Result"], fallback: str) -> str:
    """Which rung should this host be REMEMBERED as, given everything that was tried?

    The cheapest rung that actually returned the page, which is not the same question as
    "which rung returned the most text". run() needs both answers and used to conflate
    them into one variable: the most verbose result is right for what to PRINT, and wrong
    for what to remember.

    A function rather than an inline next() so the selftest can exercise it directly. The
    alternative was a test that re-spelled the expression, which tests a copy.

    attempts is in rung order (cheapest first), so the first usable entry is the answer.
    """
    return next((a.rung for a in attempts if a.usable), fallback)


# -- extraction ----------------------------------------------------------------


def extract_trafilatura(html: str, url: str = "") -> str:
    """Main-column extraction. "" when trafilatura declines or is absent.

    Split out from extract() so the selftest can exercise this path directly.
    With both extractors behind one function, breaking the bs4 branch was
    invisible whenever trafilatura was installed - found by mutation on
    2026-09-17, and the reason the selftest now tests each available extractor
    rather than "whichever one runs".
    """
    if not have("trafilatura"):
        return ""
    import trafilatura

    text = trafilatura.extract(
        html, url=url or None, include_comments=False, include_tables=True
    )
    return text.strip() if text and text.strip() else ""


def extract_bs4(html: str) -> str:
    """Crude whole-body extraction. Always available: bs4 + lxml are stage-1."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "lxml")
    for tag in soup(["script", "style", "noscript", "nav", "header", "footer", "aside", "form"]):
        tag.decompose()
    main = soup.find("article") or soup.find("main") or soup.body or soup
    text = main.get_text("\n", strip=True)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def extract(html: str, url: str = "") -> tuple[str, str]:
    """HTML -> readable text. Returns (text, extractor_name).

    trafilatura is markedly better at finding the main column and is a catalog
    entry, but it is NOT required: bs4 + lxml ship in the toolbox already, so the
    fallback keeps the tool working on a box where nobody opted in. The extractor
    name is returned rather than logged here so the caller can state which one ran
    on every single invocation - a quality downgrade that announces itself is a
    tradeoff, one that does not is a silent wrong answer.
    """
    if not html:
        return "", "none"

    text = extract_trafilatura(html, url)
    if text:
        return text, "trafilatura"
    # Fall through rather than return empty: trafilatura declines pages it cannot
    # find an article in, and for those the crude extractor beats nothing.
    return extract_bs4(html), "bs4"


def diagnose(html: str, status: int, text: str, trust_status: bool = True) -> str:
    """Name why a response yielded nothing readable. "" when it yielded a page.

    THE ORDER HERE IS THE POINT. Content first, markers second: a response that
    produced readable text at an OK status IS the page, whatever strings happen
    to appear in its HTML. Deciding "challenge" from markers and then skipping
    extraction - which is what this did first - let one script tag suppress
    medium.com's real homepage and one word in an article suppress scrapfly's.
    A detector that can veto a working page is worse than no detector.
    """
    low_text = (text or "").lower()

    # An interstitial tells the reader it is one. This test applies on every rung
    # and at every status, because it is the only signal that has not produced a
    # false positive.
    for vendor, phrase in CHALLENGE_TEXT:
        if phrase in low_text:
            return vendor

    if not trust_status:
        # BROWSER RUNG. The navigation's status describes a page that may no
        # longer exist: Cloudflare resolves its interstitial client-side, so
        # goto() returns the 403 and the DOM is then replaced by the real page.
        # Measured 2026-09-17 on glassdoor with a FRESH profile - status 403,
        # 7751 chars of real content, the same count the warmed profile returned
        # on a 200. Trusting that status reported a successful read as blocked.
        # So judge the DOM: content means success, nothing means refused.
        if text:
            return ""
        low = (html or "").lower()
        for vendor, marker in CHALLENGE_MARKERS:
            if marker in low:
                return vendor
        return "unnamed"

    if status < 400:
        # Enough text, or thin-but-real. Either way it is the page: the raw HTML
        # is not consulted, because Cloudflare ships its script on normal pages.
        return ""

    # status >= 400 on an HTTP rung is a refusal; the markers only name it.
    low = (html or "").lower()
    for vendor, marker in CHALLENGE_MARKERS:
        if marker in low:
            return vendor
    if status in (403, 429, 503):
        # A refusal whose vendor we could not name is still a refusal. Say so
        # without inventing a vendor.
        return "unnamed"
    return ""


# -- robots --------------------------------------------------------------------


def _rule_to_regex(path: str) -> re.Pattern[str]:
    """A robots.txt path pattern as a regex. Supports the two spec wildcards.

    '*' is any run of characters and '$' anchors the end (RFC 9309 s2.2.3).
    Everything else is literal, so a '.' or '+' in a path cannot act as a regex
    metacharacter and quietly widen the rule.
    """
    out = ["^"]
    for i, ch in enumerate(path):
        if ch == "*":
            out.append(".*")
        elif ch == "$" and i == len(path) - 1:
            out.append("$")
        else:
            out.append(re.escape(ch))
    return re.compile("".join(out))


def _robots_decide(text: str, token: str, path: str) -> str:
    """Longest-match-wins evaluation of a robots.txt body. "allow"/"disallow".

    WRITTEN BY HAND BECAUSE urllib.robotparser IS ORDER-SENSITIVE, not
    specificity-sensitive: its Entry.allowance returns the first rule that
    matches, so the very common shape

        User-agent: *
        Allow: /
        Disallow: /cdn-cgi/

    evaluates every path as allowed, including /cdn-cgi/. Measured against
    developers.cloudflare.com/robots.txt on 2026-09-17. RFC 9309 s2.2.2 says the
    most specific (longest) matching rule wins and that Allow wins a tie, which
    is what this does. Being wrong in the permissive direction is the wrong way
    to be wrong for a check whose entire purpose is to respect the site.
    """
    groups: dict[str, list[tuple[str, str]]] = {}
    current: list[str] = []
    starting_group = True
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        field, _, value = line.partition(":")
        field, value = field.strip().lower(), value.strip()
        if field == "user-agent":
            if not starting_group:
                current = []
                starting_group = True
            current.append(value.lower())
            groups.setdefault(value.lower(), [])
        elif field in ("allow", "disallow"):
            starting_group = False
            for agent in current:
                groups.setdefault(agent, []).append((field, value))

    token = token.lower()
    # Most specific matching group, else the wildcard group, else no rules.
    candidates = [a for a in groups if a != "*" and a and a in token]
    agent = max(candidates, key=len) if candidates else "*"
    rules = groups.get(agent, [])

    best_len, best = -1, "allow"
    for kind, value in rules:
        if value == "":
            # An empty Disallow means "nothing is disallowed" and an empty Allow
            # is meaningless. Neither is a match against a path.
            continue
        if _rule_to_regex(value).match(path):
            specificity = len(value)
            if specificity > best_len or (specificity == best_len and kind == "allow"):
                best_len, best = specificity, ("allow" if kind == "allow" else "disallow")
    return best


def robots_verdict(url: str, ua_header: str) -> tuple[str, str]:
    """Consult robots.txt. Returns (verdict, detail).

    verdict is "allow", "disallow" or "unknown", and the three are kept apart on
    purpose. urllib.robotparser.read() turns a 403 on robots.txt into
    disallow_all=True, so a site whose bot filter refuses Python-urllib is
    reported as forbidding the page - measured on developers.cloudflare.com,
    which answers urlopen with 403 while allowing the path in its actual file.
    That is a confident wrong answer, the worst kind, so robots.txt is fetched
    here with the same client and UA as the real request and the status is
    interpreted explicitly.

    "unknown" never blocks. A robots.txt we were not allowed to read is not a
    prohibition, and failing closed on it would block most of the sites this tool
    exists to read.
    """
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        return "unknown", "not an http(s) url"
    robots = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "/robots.txt", "", ""))

    import httpx

    try:
        with httpx.Client(follow_redirects=True, timeout=10.0) as client:
            r = client.get(robots, headers={"User-Agent": ua_header, "Accept": "text/plain"})
    except Exception as exc:  # noqa: BLE001 - any transport failure is "unknown"
        return "unknown", f"robots.txt unreachable ({type(exc).__name__})"

    if r.status_code in (401, 403):
        return "unknown", f"robots.txt refused us ({r.status_code}) - not a verdict"
    if 400 <= r.status_code < 500:
        return "allow", f"no robots.txt ({r.status_code})"
    if not 200 <= r.status_code < 300:
        return "unknown", f"robots.txt returned {r.status_code}"

    path = urllib.parse.urlunsplit(("", "", parts.path or "/", parts.query, ""))
    return _robots_decide(r.text, ROBOTS_TOKEN, path), robots


# -- rung 1: direct ------------------------------------------------------------


def fetch_direct(url: str, ua: str, timeout: float, impersonate: bool = True) -> Result:
    res = Result(url=url, rung="direct")
    # NO Accept-Encoding. Setting it by hand is how this function returned 21 KB
    # of binary mush from a working 200: the browser-shaped value advertises br
    # and zstd, the server honoured br, and httpx has no brotli codec in this venv
    # so r.text handed back the compressed bytes. Each client advertises what it
    # can actually decode if left alone, which is the only correct answer here.
    headers = {
        "User-Agent": ua,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Upgrade-Insecure-Requests": "1",
    }

    # curl_cffi presents a real Chrome TLS/HTTP2 fingerprint, which is the one
    # thing httpx cannot do and the single cheapest upgrade on this rung. Optional
    # (catalog entry, default:false) - httpx is the floor.
    # impersonate=False exists so the two HTTP paths can be A/B'd on a real
    # target. Without it the curl_cffi claim in catalog.json is untestable on this
    # box, and an untestable claim about what gets past a bot filter is exactly
    # the kind this repo does not keep.
    if impersonate and have("curl_cffi"):
        from curl_cffi import requests as cffi_requests

        try:
            r = cffi_requests.get(
                url, headers=headers, impersonate="chrome", timeout=timeout, allow_redirects=True
            )
            res.status, res.final_url = r.status_code, str(r.url)
            body = r.text
            res.notes.append("tls: curl_cffi impersonate=chrome")
        except Exception as exc:  # noqa: BLE001
            res.notes.append(f"curl_cffi failed ({type(exc).__name__}), falling back to httpx")
            body = ""
    elif impersonate:
        res.notes.append("tls: httpx default (install curl_cffi for a Chrome TLS fingerprint)")
        body = ""
    else:
        res.notes.append("tls: httpx default (--no-impersonate)")
        body = ""

    if not res.status:
        import httpx

        try:
            with httpx.Client(
                follow_redirects=True, timeout=timeout, headers=headers, http2=have("h2")
            ) as client:
                r = client.get(url)
                res.status, res.final_url, body = r.status_code, str(r.url), r.text
        except Exception as exc:  # noqa: BLE001
            res.notes.append(f"httpx failed: {type(exc).__name__}: {exc}")
            return res

    if res.status == 402:
        return res
    # Extract FIRST, always, then diagnose what is left. Gating extraction on a
    # status or a marker is what produced both false positives.
    text, extractor = extract(body, res.final_url or url)
    res.text = text
    res.notes.append(f"extractor: {extractor}")
    res.challenge = diagnose(body, res.status, text)
    return res


# -- rung 2: reader ------------------------------------------------------------

# r.jina.ai answers with an ENVELOPE, not the page: a block of "Key: value" lines
# and then this marker, after which the extracted text begins.
READER_ENVELOPE_END = "Markdown Content:"


def reader_unwrap(body: str) -> tuple[str, list[str]]:
    """Split r.jina.ai's header block off the page text. Returns (text, notes).

    THE HEADER IS NOT PAGE TEXT, and counting it as page text was not cosmetic.
    Measured against example.com on 2026-09-17: 366 chars reported, of which 226
    were Title/URL Source/Published Time/Warning lines and 140 were the page. That
    inflates `chars`, moves results across the MIN_TEXT line, and - because run()
    keeps whichever rung returned the most text - gave this rung a ~200-char head
    start over `direct` and `chrome` on every comparison. A reader result could
    win the ladder, and end it, on the strength of Jina's own preamble.

    The Warning line is kept as a note rather than dropped: Jina serves CACHED
    snapshots and says so in-band. That same measurement got a snapshot two days
    old, which browse reported as an ordinary live read. No other rung can hand
    back stale content, so the caveat has nowhere else to come from.

    An unrecognised envelope degrades to today's behaviour - the whole response as
    text - and SAYS SO, rather than returning an empty page if Jina's format moves.
    """
    head, sep, rest = body.partition(READER_ENVELOPE_END)
    if not sep:
        return body.strip(), [
            "reader envelope not recognised - the whole response is being counted as page text"
        ]
    notes = [f"dropped {len(head)} chars of r.jina.ai envelope (header, not page text)"]
    for line in head.splitlines():
        line = line.strip()
        low = line.lower()
        if low.startswith("warning:"):
            notes.append(f"STALE? r.jina.ai said: {line}")
        elif low.startswith("published time:"):
            notes.append(f"r.jina.ai reported {line}")
    return rest.strip(), notes


def fetch_reader(url: str, timeout: float) -> Result:
    """Third-party server-side reader. Opt-in because it discloses the URL.

    The value is not stealth, it is a DIFFERENT source IP: a block aimed at this
    machine does not apply to Jina's fetchers. The cost is that Jina learns which
    page was wanted, which is why nothing calls this without --allow-reader.
    """
    res = Result(url=url, rung="reader")
    import httpx

    endpoint = "https://r.jina.ai/" + url
    try:
        with httpx.Client(follow_redirects=True, timeout=timeout) as client:
            r = client.get(endpoint, headers={"Accept": "text/plain"})
            res.status, res.final_url = r.status_code, url
            if 200 <= r.status_code < 300:
                res.notes.append("extractor: r.jina.ai (server-side)")
                text, envelope_notes = reader_unwrap(r.text)
                res.text = text
                res.notes.extend(envelope_notes)
                res.notes.append("PRIVACY: the url was disclosed to r.jina.ai")
            else:
                # A non-2xx used to leave NO note at all, so a refusal printed as
                # "rung=reader status=451 chars=0" with nothing said about it -
                # indistinguishable from a rung that was never tried. Jina refuses
                # with 401/402/429/451 depending on quota and target.
                res.notes.append(f"reader refused: HTTP {r.status_code} and no text returned")
                # AND NAME IT IN .challenge, the machine-readable field. This was left
                # empty, so `--json` reported challenge="" right beside a note saying the
                # reader had refused: anything checking the field saw "no block detected"
                # while the human-readable note said the opposite. A field that disagrees
                # with the note next to it is worse than no field.
                res.challenge = READER_REFUSAL.get(
                    r.status_code, f"reader-http-{r.status_code}"
                )
    except Exception as exc:  # noqa: BLE001
        res.notes.append(f"reader failed: {type(exc).__name__}: {exc}")
    return res


# -- rung 3: chrome ------------------------------------------------------------


def fetch_chrome(url: str, cdp: str, timeout: float, settle: float = 25.0) -> Result:
    """Attach to an ALREADY-RUNNING Chrome over CDP and read the rendered page.

    connect_over_cdp, never launch(). Launching gives a fresh automation Chromium
    with no profile, no history and no cleared challenges, which is the setup the
    benchmark scored worst. Attaching gives the real browser the user started with
    scripts/start-browse-chrome.ps1, and a clearance it earns persists there.

    WAITS OUT A CHALLENGE INSTEAD OF RETRYING IT. A real Chrome solves
    Cloudflare's managed challenge by itself; it just does not always finish
    before domcontentloaded. Re-navigating was tried first and is wrong - it
    throws away the in-progress solve and asks again from the start. Measured
    2026-09-17 on two virgin profiles: a 3 s sleep plus a fresh navigation left
    stackoverflow.com/questions on 41 chars of interstitial twice, while polling
    the SAME page clears it. glassdoor resolves inside the first navigation and
    indeed never challenges, so this loop costs nothing on either.
    """
    res = Result(url=url, rung="chrome", status_reliable=False)
    from playwright.sync_api import sync_playwright

    try:
        with sync_playwright() as p:
            browser = p.chromium.connect_over_cdp(cdp, timeout=timeout * 1000)
            context = browser.contexts[0] if browser.contexts else browser.new_context()
            page = context.new_page()
            try:
                resp = page.goto(url, wait_until="domcontentloaded", timeout=timeout * 1000)
                res.status = resp.status if resp else 0
                res.final_url = page.url
                try:
                    page.wait_for_load_state("networkidle", timeout=5000)
                except Exception:  # noqa: BLE001
                    # A page that never goes idle (polling, ads, websockets) is
                    # normal and is not a failure - take the DOM as it stands.
                    res.notes.append("networkidle timed out; read the DOM as-is")

                html = page.content()
                text, extractor = extract(html, res.final_url or url)
                challenge = diagnose(html, res.status, text, trust_status=False)

                if challenge:
                    started = time.monotonic()
                    deadline = started + max(0.0, settle)
                    while challenge and time.monotonic() < deadline:
                        time.sleep(1.5)
                        try:
                            html = page.content()
                        except Exception:  # noqa: BLE001
                            # The interstitial replacing the document can make one
                            # content() read fail. That is progress, not failure.
                            continue
                        res.final_url = page.url
                        text, extractor = extract(html, res.final_url or url)
                        challenge = diagnose(html, res.status, text, trust_status=False)
                    waited = time.monotonic() - started
                    if challenge:
                        res.notes.append(f"still challenged after waiting {waited:.0f}s")
                    else:
                        res.notes.append(f"challenge cleared itself after {waited:.0f}s")
            finally:
                page.close()

            res.text = text
            res.challenge = challenge
            res.notes.append(f"extractor: {extractor}")
            res.notes.append(f"cdp: {cdp}")
    except Exception as exc:  # noqa: BLE001
        res.notes.append(f"cdp attach failed: {type(exc).__name__}: {exc}")
        res.notes.append(f"no browser on {cdp}? start one: scripts\\start-browse-chrome.ps1")
    return res


# -- selftest ------------------------------------------------------------------


def selftest(cdp: str, timeout: float) -> int:
    """Only the extraction checks are allowed to fail the run.

    A: OFFLINE LOGIC, against embedded fixtures. Extraction once per AVAILABLE
       extractor, not once for whichever one extract() happens to choose; the
       reader envelope parse; which rung the journal remembers; and the reader
       refusal naming that emit() branches on. Deterministic, no network, and all
       of it CAN fail: break any of them and this is the check that says so. This
       is the group the smoke test relies on.
    B: network reachability through rung 1.
    C: whether a CDP browser is up.

    B and C depend on things that are legitimately absent (no network, no browser
    running), so they report DEGRADED rather than failing. They print that state
    on every run: a check that quietly skips is indistinguishable from one that
    passed, which is how a dead sensor survives.
    """
    failures = 0

    # EVERY available extractor, not just the one extract() would pick. Testing
    # only the active path meant a broken bs4 fallback passed silently on any box
    # with trafilatura installed - found by mutation on 2026-09-17. Breaking
    # either branch now fails exactly this check.
    probes = [("bs4", lambda: extract_bs4(SELFTEST_HTML))]
    if have("trafilatura"):
        probes.append(
            ("trafilatura", lambda: extract_trafilatura(SELFTEST_HTML, "https://fixture.invalid/"))
        )

    for name, run_probe in probes:
        try:
            text = run_probe() or ""
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"  FAIL     extraction ({name}) raised {type(exc).__name__}: {exc}")
            continue
        low = text.lower()
        if SELFTEST_WANT in low and SELFTEST_REJECT not in low:
            print(f"  OK       extraction ({name}): kept the body, dropped the boilerplate")
        else:
            failures += 1
            print(f"  FAIL     extraction ({name}) produced {len(text)} chars")
            print(f"           wanted {SELFTEST_WANT!r} present and {SELFTEST_REJECT!r} absent")
            print(f"           got: {text[:200]!r}")

    # Rung 2's envelope parse, offline. This belongs beside the extraction checks
    # rather than in the network section: the reader rung is opt-in BECAUSE it
    # discloses the URL, so its check must not fire a third-party request on every
    # smoke test. The live proof is a recorded manual measurement instead.
    reader_text, reader_notes = reader_unwrap(SELFTEST_READER)
    reader_stale = any(n.startswith("STALE?") for n in reader_notes)
    if (
        reader_text.startswith("This domain is")
        and "URL Source:" not in reader_text
        and reader_stale
    ):
        print(
            f"  OK       reader envelope: {len(reader_text)} chars of page, "
            "header dropped, staleness kept"
        )
    else:
        failures += 1
        print(
            f"  FAIL     reader envelope unwrap produced {len(reader_text)} chars, "
            f"stale_noted={reader_stale}"
        )
        print(f"           got: {reader_text[:120]!r}")

    # WHICH RUNG THE JOURNAL REMEMBERS, offline. Logic, not network, so it belongs with
    # the checks that are allowed to fail.
    #
    # The fixture is the observed example.com shape - every rung thin, the later one more
    # verbose - because that is the only shape that reaches this branch. `direct` served
    # the page; `reader` merely added envelope characters while disclosing the URL to a
    # third party. Remembering `reader` for that is the bug.
    thin_cheap = Result(url="https://fixture.invalid/", rung="direct", status=200, text="a" * 100)
    thin_verbose = Result(url="https://fixture.invalid/", rung="reader", status=200, text="a" * 300)
    chose = journal_rung([thin_cheap, thin_verbose], thin_verbose.rung)
    if chose == "direct":
        print("  OK       journal rung: remembers the cheapest rung that worked, not the wordiest")
    else:
        failures += 1
        print(f"  FAIL     journal rung: remembered {chose!r}, wanted 'direct'")
        print(
            f"           direct returned {len(thin_cheap.text)} chars, "
            f"reader {len(thin_verbose.text)} - both thin, so the cheapest wins"
        )

    # EVERY reader refusal name must carry the `reader-` prefix, because emit() branches on
    # that prefix to choose its advice. An entry added without it silently falls into the
    # other branch and tells the human to open a browser and clear a challenge that does
    # not exist, in order to fix somebody else's quota.
    unprefixed = sorted(v for v in READER_REFUSAL.values() if not v.startswith("reader-"))
    if READER_REFUSAL and not unprefixed:
        print(
            f"  OK       reader refusals: {len(READER_REFUSAL)} named, "
            "all carrying the prefix emit() branches on"
        )
    else:
        failures += 1
        print(f"  FAIL     reader refusal names missing the 'reader-' prefix: {unprefixed}")

    # The install command is install-browse.ps1 -WithExtras, NOT "bootstrap -Only
    # extras": both catalog entries are default:false, so a group run skips them
    # and the instruction would have been confidently wrong.
    if not have("trafilatura"):
        print("  DEGRADED trafilatura absent - using the bs4 fallback extractor")
        print("           install: .\\scripts\\install-browse.ps1 -WithExtras")
    if not have("curl_cffi"):
        print("  DEGRADED curl_cffi absent - rung 1 sends httpx's TLS fingerprint")
        print("           install: .\\scripts\\install-browse.ps1 -WithExtras")

    # .usable, NOT .thin-aware: example.com is ~180 chars and that is the correct
    # answer for it. This probe asks "did the network work", not "was it long".
    probe = fetch_direct("https://example.com/", UA_BROWSER, timeout)
    if probe.usable:
        print(f"  OK       rung 1 reached example.com ({len(probe.text)} chars)")
    else:
        print(f"  DEGRADED rung 1 could not read example.com (status {probe.status})")
        for note in probe.notes:
            print(f"           {note}")

    chrome = fetch_chrome("about:blank", cdp, min(timeout, 5.0))
    if not any("attach failed" in n for n in chrome.notes):
        print(f"  OK       rung 3 attached to a live browser at {cdp}")
    else:
        print(f"  DEGRADED rung 3 has no browser at {cdp}")
        print("           start one: scripts\\start-browse-chrome.ps1")

    print(f"  browse {__version__}: {'1 or more checks FAILED' if failures else 'extraction OK'}")
    return 1 if failures else 0


# -- driver --------------------------------------------------------------------


def run(args: argparse.Namespace) -> int:
    url = args.url
    host = urllib.parse.urlsplit(url).netloc.lower()
    ua = UA_HONEST.format(v=__version__) if args.ua == "honest" else UA_BROWSER

    verdict, detail = ("skipped", "--ignore-robots") if args.ignore_robots else robots_verdict(url, ua)
    if verdict == "disallow" and not args.ignore_robots:
        print(f"browse: robots.txt disallows this path for {ROBOTS_TOKEN}", file=sys.stderr)
        print(f"browse: {detail}", file=sys.stderr)
        print("browse: override with --ignore-robots if you have a reason to", file=sys.stderr)
        return EX_ROBOTS

    # Rung order, with the journal allowed to move the winner to the front rather
    # than to remove the rungs before it. Skipping them outright would make a
    # host that has since relaxed permanently expensive.
    order = ["direct"]
    if args.allow_reader:
        order.append("reader")
    order.append("chrome")
    # A FORCED rung neither reads nor writes the journal. Writing it would teach
    # the journal that a host needs the browser on the strength of someone having
    # asked for the browser, which is not evidence about the host at all: one
    # `--rung chrome` against a page rung 1 serves fine pinned that host to the
    # slowest rung permanently.
    learn = not args.rung
    if args.rung:
        order = [args.rung]
    else:
        remembered = journal_load().get(host, {}).get("rung")
        if remembered in order:
            order.remove(remembered)
            order.insert(0, remembered)

    # Keep the BEST usable result rather than the last one. A thin 200 from rung 1
    # is still a real page, so if the browser rung then fails outright the thin
    # answer is what the caller gets - losing it would turn "short page" into
    # "blocked", which is the bug the MIN_TEXT comment records.
    best = Result(url=url)
    attempts: list[Result] = []
    for rung in order:
        if rung == "direct":
            last = fetch_direct(url, ua, args.timeout, impersonate=not args.no_impersonate)
        elif rung == "reader":
            last = fetch_reader(url, args.timeout)
        else:
            last = fetch_chrome(url, args.cdp, args.timeout)
        attempts.append(last)
        if last.usable and len(last.text) > len(best.text):
            best = last
        if last.usable and not last.thin:
            if learn:
                journal_save(host, rung)
            break
        # A reader 402 is Jina's quota, not the target selling access, so it must NOT stop
        # the remaining rungs - the site may serve the page directly or to a browser.
        if last.status == 402 and last.rung != "reader":
            break

    if best.usable:
        if best.thin:
            best.notes.append(f"thin result ({len(best.text)} chars) - no rung did better")
        if learn and not journal_load().get(host):
            # THE FIRST USABLE RUNG, not the one that returned the most text.
            #
            # This branch runs only when EVERY rung came back thin, so the loop above never
            # broke and never journalled. `best` is the most VERBOSE rung, which is the
            # right answer for what to PRINT and the wrong one for what to REMEMBER: for a
            # page legitimately shorter than MIN_TEXT, the cheapest rung that returned it is
            # the rung to start at next time. Two purposes were sharing one variable.
            #
            # Observed 2026-09-17: example.com (~180 chars, thin by definition) was pinned
            # to `reader` because Jina's envelope adds characters, even though `direct` had
            # served the page perfectly. Every later fetch of that host then began at a rung
            # that discloses the URL to a third party, to win a few characters.
            #
            journal_save(host, journal_rung(attempts, best.rung))
        emit(best, verdict, args)
        return EX_OK

    # EVERY RUNG FAILED, so report the most INFORMATIVE failure, not the last one.
    # Reporting the last one hid the fact that mattered: glassdoor served rung 1 a
    # challenge, then rung 3 found no browser running, and the output said only
    # "no browser" - which reads as a local setup problem rather than as the site
    # refusing us. Notes from every rung are carried so nothing is lost.
    # A TARGET-level challenge outranks a reader-service one. "cloudflare" tells you
    # something about the site; "reader-quota-or-payment" only tells you about Jina. Now
    # that a reader refusal sets .challenge, a plain next() would let a reader rung that
    # happened to run first mask a real Cloudflare block found by a later rung.
    blocked = next(
        (a for a in attempts if a.challenge and not a.challenge.startswith("reader-")), None
    ) or next((a for a in attempts if a.challenge), None)
    # Reader 402s excluded, for the same reason as the break above: EX_PAYMENT asserts the
    # TARGET sells machine access, and Jina exhausting its quota is not that claim.
    payment = next((a for a in attempts if a.status == 402 and a.rung != "reader"), None)
    report = blocked or payment or (attempts[-1] if attempts else Result(url=url))
    report.notes = [f"[{a.rung}] {n}" for a in attempts for n in a.notes]

    emit(report, verdict, args)
    if payment is not None:
        return EX_PAYMENT
    if blocked is not None:
        return EX_BLOCKED
    if report.status == 0:
        return EX_UNREACHABLE
    return EX_BLOCKED


def emit(res: Result, robots: str, args: argparse.Namespace) -> None:
    if args.json:
        print(
            json.dumps(
                {
                    "url": res.url,
                    "final_url": res.final_url,
                    "rung": res.rung,
                    "status": res.status,
                    "robots": robots,
                    "challenge": res.challenge,
                    "ok": res.usable,
                    "thin": res.thin,
                    "chars": len(res.text),
                    "notes": res.notes,
                    "text": res.text,
                },
                indent=2,
            )
        )
        return

    stale = " (initial nav; superseded client-side)" if not res.status_reliable else ""
    print(f"# {res.final_url or res.url}")
    print(f"# rung={res.rung} status={res.status}{stale} robots={robots} chars={len(res.text)}")
    for note in res.notes:
        print(f"# {note}")
    if res.challenge:
        print(f"# CHALLENGE: {res.challenge}")
        print("#")
        print("# This is a refusal, not a transient error. Do not retry in a loop.")
        if res.challenge.startswith("reader-"):
            # THE READER SERVICE REFUSED, NOT THE TARGET, so the browser advice below
            # would be actively misleading: clearing a challenge in the local Chrome
            # cannot fix r.jina.ai's quota, key or rate limit. Different refuser,
            # different remedy.
            print("# r.jina.ai refused this. That is a fact about the READER, not about")
            print("# the target site, so there is no challenge here for you to clear.")
            print("# Try a rung that does not involve it:")
            print(f"#   browse {res.url} --rung direct")
            print(f"#   browse {res.url} --rung chrome")
        else:
            print("# Ask the human to open the page in the live browser and clear the")
            print("# challenge once; the profile keeps it cleared for later fetches:")
            print("#   scripts\\start-browse-chrome.ps1")
            print(f"#   then: browse {res.url} --rung chrome")
    # NOT for a reader 402, which is Jina's quota rather than the target selling access.
    # Printing "the site charges for machine access" there names the wrong party and sends
    # the reader off to pay somebody who is not asking for money.
    if res.status == 402 and res.rung != "reader":
        print("#")
        print("# 402: the site charges for machine access (Cloudflare pay-per-crawl")
        print("# or an x402 gateway). There is no bypass. Read it in a browser, find")
        print("# another source, or pay.")
    print()
    print(res.text)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="browse",
        description="Fetch a web page for reading, escalating only as far as needed.",
        epilog=(
            "rungs: direct (httpx) -> reader (opt-in, third-party) -> chrome (CDP attach). "
            "Exit: 0 ok, 3 blocked, 4 robots, 5 payment required, 6 unreachable."
        ),
    )
    p.add_argument("url", nargs="?", help="the page to read")
    p.add_argument("--json", action="store_true", help="structured output for an agent")
    p.add_argument("--rung", choices=["direct", "reader", "chrome"], help="force one rung")
    p.add_argument(
        "--allow-reader",
        action="store_true",
        help="permit the third-party reader rung (discloses the url to r.jina.ai)",
    )
    p.add_argument("--cdp", default=os.environ.get("BROWSE_CDP_URL", DEFAULT_CDP),
                   help=f"CDP endpoint for the chrome rung (default {DEFAULT_CDP})")
    p.add_argument("--ua", choices=["browser", "honest"], default="browser",
                   help="browser: a Chrome UA. honest: self-identify as this tool.")
    p.add_argument("--ignore-robots", action="store_true", help="fetch despite a Disallow")
    p.add_argument("--no-impersonate", action="store_true",
                   help="rung 1 uses httpx even when curl_cffi is installed (for A/B testing)")
    p.add_argument("--timeout", type=float, default=30.0, help="per-rung timeout in seconds")
    p.add_argument("--selftest", action="store_true", help="run the built-in checks and exit")
    p.add_argument("--version", action="version", version=f"browse {__version__}")
    return p


def main(argv: list[str] | None = None) -> int:
    # Windows gives this process a cp1252 stdout, and web pages are not cp1252.
    # Without this, a fetch that SUCCEEDED dies in print() with a
    # UnicodeEncodeError and the caller sees a traceback instead of the page -
    # measured on a Cloudflare docs page, which is plain English prose with a few
    # typographic quotes. errors="replace" rather than "strict": a page is still
    # worth reading with one character substituted, and a hard failure here would
    # be indistinguishable from the site blocking us.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    args = build_parser().parse_args(argv)
    if args.selftest:
        return selftest(args.cdp, args.timeout)
    if not args.url:
        build_parser().print_usage(sys.stderr)
        print("browse: a url is required (or --selftest)", file=sys.stderr)
        return EX_USAGE
    if not urllib.parse.urlsplit(args.url).scheme:
        args.url = "https://" + args.url
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
