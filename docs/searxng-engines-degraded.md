# SearXNG: the scraping engines are blocked, and one of them lies about it

**Diagnosed 2026-08-31** against `10.100.0.2:8888`
(`hosts/common/optional/ai/searxng.nix`, enabled on `server-nixos`).

**Root cause: the instance's outbound IP has scraper reputation with the
commercial search engines.** Four of them say so outright. Bing does not — it
returns ten confident, entirely unrelated results instead, which is why the
symptom looked like six unrelated faults rather than one.

**This is not a misconfiguration and it is not fixable by tuning.** Refusing
self-hosted metasearch is what those engines are built to do. The fix is to
stop scraping, and there are four API-backed engines already working on this
instance today.

---

## 1. What works right now — no config change needed

Probed with `Nothofagus`, a term generic enough to be indexed everywhere and
distinctive enough that irrelevance is obvious:

| engine | kind | results | relevant | verdict |
|---|---|---|---|---|
| **crossref** | API | 20 | 25 mentions | ✅ best coverage |
| **openalex** | API | 10 | 11 mentions | ✅ |
| **wikispecies** | API | 5 | 10 mentions | ✅ |
| **wikipedia** | API | 2 | 1 mention | ✅ narrow but correct |
| pubmed | API | 20 | 0 | honest — a medical corpus has no *Nothofagus* |
| arxiv, wikidata | API | 0 | 0 | no match, reported cleanly |

**None of these are scrapers.** They are documented APIs with no anti-bot layer,
so none of them can be blocked for looking like a robot — they expect robots.
`crossref` rate-limits after roughly one query and says so.

## 2. What is broken, and how each one fails

| engine | kind | state | fails how |
|---|---|---|---|
| duckduckgo | scraper | CAPTCHA | honest — reported in `unresponsive_engines` |
| brave | scraper | Suspended: too many requests | honest |
| mojeek | scraper | Suspended: access denied | honest |
| qwant | scraper | Suspended: access denied | honest |
| google | scraper | disabled in config | deliberate; the comment explains why |
| **bing** | scraper | **serves generic filler** | ⚠️ **silent — no error at any layer** |

Four engines independently reporting "access denied / too many requests /
CAPTCHA" for the same host is the diagnosis. They are describing the same fact
about the same IP.

## 3. Why bing is the dangerous one

Probed with seven queries, each paired with the distinctive term that must
appear if the search worked:

| query | n | results mentioning the term |
|---|---|---|
| `Larix decidua` | 10 | 10 ✅ |
| `larch boreal forest` | 10 | 10 ✅ |
| `tropical montane cloud forest Quercus` | 10 | **0** ⚠️ |
| `Brachystegia` | 10 | **0** ⚠️ |
| `Brachystegia miombo woodland canopy` | 10 | **0** ⚠️ |
| `alder carr temperate swamp` | 10 | **0** ⚠️ |
| `Nothofagus` | 10 | **0** ⚠️ |

**3 of 7 relevant**, and the two outcomes are indistinguishable from outside:
same status, same count, same JSON shape, `unresponsive_engines: []`.

The filler is not stable and not even geographically coherent — the *same*
query returns different junk on consecutive runs:

    Brachystegia          -> ssa.gov (Social Security), then dclottery.com
    Nothofagus            -> city-data forums, youtube.com/?gl=ES,
                             segurosocial.app/site/mx/, support.google.com

US, Spain, Mexico, in one result set. That is a generic high-traffic fallback
page, served fresh each time.

## 4. What was ruled out, and how

Each of these was a plausible root cause and each is **refuted by measurement**,
recorded so nobody re-runs them:

| hypothesis | test | result |
|---|---|---|
| VPN / datacenter egress | `nordvpn.nix` imports | ❌ workstation+laptop only, never completed. Server egress is residential |
| Stale package | running version | ❌ `2026.05.16+dce3bb69`, one release behind |
| Broken parser in old version | diffed `bing.py` old vs new | ❌ **the result-extraction XPath is unchanged** — upgrading would not have fixed it |
| Bing blocks this IP | `curl` from the server | ❌ HTTP 200, 124 KB, **8 mentions of the query term**, no CAPTCHA |
| User-agent filtering | 4 UAs incl. none and `python-requests` | ❌ all four correct |
| Query params (`adlt`, `mkt`, `setlang`) | each isolated | ❌ all six variants correct |
| `Accept-Language` header | isolated | ❌ correct |
| HTTP client fingerprint | `httpx` h2 + h1.1 from the server | ❌ both correct, 22 mentions |
| Redirect following (`allow_redirects`) | `curl -L` vs plain | ❌ `redirects=0`, no redirect occurs |
| Outbound proxy | runtime `settings.yml` | ❌ none configured |
| Rate-limit that recovers | cold queries after a pause | ❌ still filler |

Every hand-built request from that host gets correct results. Only SearXNG's own
request pattern does not — which is consistent with reputation attached to the
traffic pattern rather than to any single request attribute.

## 5. The fix

1. **Drop `bing`.** ✅ DONE (disabled in `searxng.nix`). It is worse than no engine: a blocked engine is visibly
   blocked, this one is not, and nothing downstream can compensate for a source
   that fabricates plausibly.
2. **Switch the default engine set to the APIs** ✅ DONE — `crossref`, `openalex`,
   `wikipedia`, `wikispecies` — which already work. This changes what the
   instance is good at (technical, scientific and reference questions rather
   than general web) and that is the honest trade, not a regression.
3. **If general web search is required, buy an API key.** Brave Search API,
   Azure/Bing API, Tavily, Exa. SearXNG supports key-based engines. This is the
   only actual root-cause fix, because it stops the instance being a scraper.
   Everything else is cat-and-mouse with a party that has decided the answer.
4. **Add a sentinel** in the `fleet-sentinel.nix` mould ✅ DONE (`search-sentinel.nix`, 08:15/20:15): query a fixed rare term
   on a schedule and assert the term appears in the results. A liveness check on
   :8888 passes today and tells you nothing. This is the lab's own
   count-beside-a-verdict rule applied to a service whose verdict is currently
   "200 OK" over content nobody inspected.
5. ❌ **REJECTED 2026-08-31 — took the service down (HTTP 500 on every route); see
   `hosts/common/optional/ai/searxng.nix`.** Original proposal: **bump the package** to `pkgs.unstable.searxng` (`2026-07-26` vs the running
   `2026-05-16`) — cheap and worth doing, following the existing
   `pkgs.unstable.*` pattern. ⚠️ **But do not expect it to fix bing**: the
   parsing code is byte-identical between the two.

## 6. The probe lied first, twice, and both are the same mistake

Recorded because the write-up nearly shipped with each of them.

**The version.** `ls /nix/store/*searx*` reported a February build. That is the
store's *history*, not what is running; the live version came from the uwsgi
vassal's python env and is May. Listing a directory is not reading a
configuration.

**The relevance test.** The first probe compared each query's results against
those of its first word alone, on a truncation theory. Three of four pairs came
back byte-identical, which looked conclusive — and the fourth *differed*, so the
probe scored it **"honoured"**. Both sets in that pair were garbage. A test that
compares two outputs to each other and never asks whether either is correct
cannot tell working from broken, and it awarded a pass to the worst case in the
set.

The fixed probe asks the only question that settles it: does the query's own
rarest word appear anywhere in ten titles and URLs?

## 7. What it cost

Nothing this time, and only because it was caught before it was trusted. A
research pass was about to run through this endpoint; the output would have been
findings sourced from a Malaysian tech forum and a benefits page, in a document
that marks every claim cited or uncited. The citations would have been real
URLs pointing at the wrong pages, and nothing at any layer would have flagged
it.

The general form, which is not specific to one consumer:

**An engine that fails loudly costs you an answer. One that fails silently costs
you a wrong answer you will act on.**
