# SearXNG — self-hosted metasearch for the AI lab (web search for agents/Open WebUI).
# wg0-only, served via uwsgi. Secret key generated off-git (never in the repo).
#
# ⚠️ THIS IS AN API-BACKED INSTANCE, NOT A WEB-SCRAPING ONE, and that is the
# whole design after 2026-08-31. Every commercial engine that works by scraping
# refuses this host: measured, four of them say so outright (duckduckgo CAPTCHA,
# brave "too many requests", mojeek and qwant "access denied"), and Bing does
# NOT — it silently serves ten unrelated results instead. Full diagnosis,
# including eleven refuted hypotheses, in docs/searxng-engines-degraded.md.
#
# The reputation is attached to the traffic PATTERN, not to any request
# attribute: curl and httpx from this same host, with any user-agent and any
# parameters, get correct results every time. So there is nothing to tune. The
# engines that work are the ones that expect robots — documented APIs.

{ pkgs, net, ... }:

{
  services.searx = {
    enable = true;
    # ⚠️ DO NOT SET `package = pkgs.unstable.searxng`. IT TAKES THE SERVICE DOWN,
    # and it did on 2026-08-31 — a total outage, HTTP 500 on every route
    # including the root page, from a one-line change whose own comment called
    # it optional hygiene.
    #
    # WHY IT BREAKS. The NixOS module builds uwsgi's interpreter from the STABLE
    # `python3` (3.13.15) and expects `cfg.package` to live inside that env.
    # `pkgs.unstable.searxng` is built against python **3.14**, so it lands in a
    # different site-packages tree that the vassal's PythonHome never sees. The
    # symptom is `ModuleNotFoundError: No module named 'searx'`, followed by
    # `no app loaded. going in full dynamic mode` — uwsgi stays UP and serves
    # 500s, so the unit reads `active` throughout. Measured: the vassal env's
    # site-packages contained 0 files matching searx.
    #
    # The lab's `pkgs.unstable.*` pattern works for ollama-rocm and sunshine
    # because those are standalone binaries. It does NOT transfer to a module
    # that constructs its own Python environment: the package and the
    # interpreter have to come from the same nixpkgs.
    #
    # Nothing was lost by reverting. The version bump was never the fix —
    # bing.py's result-extraction XPath is byte-identical between 2026-05-16 and
    # 2026-07-26 — and the engine list below is what actually repairs search. If
    # a newer SearXNG is ever genuinely wanted, it needs the whole module moved
    # to unstable (`services.searx` from nixpkgs-unstable), not one package
    # swapped underneath a stable module.
    # Secret injected via envsubst from this file (generated below, not in git).
    environmentFile = "/var/lib/searx-secret/secret.env";
    configureUwsgi = true;
    uwsgiConfig = {
      http = "${net.wireguard.meshIPs.server-nixos}:8888"; # wg0
      disable-logging = true;
    };
    settings = {
      server.secret_key = "$SEARX_SECRET_KEY"; # substituted from environmentFile
      server.bind_address = "${net.wireguard.meshIPs.server-nixos}";
      server.port = 8888;
      general.instance_name = "lab-search";
      # JSON enabled for programmatic use by the research tool.
      search.formats = [ "html" "json" ];

      # ENGINES. Measured 2026-08-31 with the probe term `Nothofagus` — generic
      # enough to be indexed everywhere, distinctive enough that irrelevance is
      # unmistakable. Counts are results / results actually mentioning the term.
      engines = [
        # ── DISABLED: scrapers this host is blocked from ───────────────────
        #
        # ⚠️ bing is the ONLY ONE THAT HAD TO BE TURNED OFF RATHER THAN LEFT TO
        # FAIL, and it is the reason this list exists. It returns HTTP 200 with
        # exactly ten results and an EMPTY `unresponsive_engines`, so nothing at
        # any layer reports a problem — but 4 of 7 probe queries came back with
        # zero results mentioning their own distinctive term. `Brachystegia`
        # returned Social Security pages on one run and DC Lottery on the next;
        # `Nothofagus` returned city-data forums, youtube.com/?gl=ES and a
        # Mexican benefits site in one result set. Generic high-traffic filler,
        # served fresh each time.
        #
        # A blocked engine costs an answer. This one costs a WRONG answer that
        # nothing flags, which is strictly worse — leaving it enabled would keep
        # feeding fabricated-but-plausible sources to every consumer.
        { name = "bing"; disabled = true; }
        # Google blocks self-hosted scrapers (403 spam). Predates this pass.
        { name = "google"; disabled = true; }
        # These three fail HONESTLY — they report themselves unresponsive and
        # SearXNG passes that through, so they cost latency rather than trust.
        # Disabled anyway: 100% failure is not worth the round-trip on every
        # query, and re-enabling is a one-line change if reputation recovers.
        { name = "duckduckgo"; disabled = true; }   # CAPTCHA
        { name = "brave"; disabled = true; }        # Suspended: too many requests
        { name = "qwant"; disabled = true; }        # Suspended: access denied
        { name = "mojeek"; disabled = true; }       # Suspended: access denied
        # ⚠️ MISSED IN THE FIRST PASS AND CAUGHT ONLY BY READING A LIVE DEFAULT
        # QUERY. startpage is `categories: [general, web]` and NOT disabled
        # upstream, so it was still being queried after the first deploy and
        # still failing — `unresponsive_engines: [["startpage", "Suspended:
        # CAPTCHA"]]` on every default search. It failed honestly, so it cost a
        # round-trip rather than a wrong answer, but it was in the list of
        # blocked engines from the very first probe of this investigation and I
        # did not carry it across. Disabling engines one at a time from memory
        # is how one survives; the check is a default query, not the config.
        { name = "startpage"; disabled = true; }    # Suspended: CAPTCHA

        # ── ENABLED: APIs, which cannot be blocked for looking like a robot ──
        # They expect robots. That is the entire reason these still work while
        # every scraper above does not.
        # ⭐ `categories` IS THE HALF THAT ENABLING ALONE DOES NOT BUY, and it
        # was missing from the first deploy. Upstream files these two under
        # `[science, scientific publications]` ONLY, and a default query
        # searches `general` — so after the first pass they were enabled,
        # reachable via `engines=crossref`, and ABSENT from every query a
        # consumer actually makes. Measured on the live instance: a default
        # query returned 5 results from wikispecies alone, while
        # `categories=science` returned ~95 across 8 engines.
        #
        # ⚠️ THE PROBE THAT MISSED THIS IS MY OWN SENTINEL. It queries each
        # engine with an explicit `engines=X`, and explicit selection BYPASSES
        # `disabled` entirely — proven by bing, which is disabled here and still
        # returns 10 results when named. So per-engine probes cannot tell an
        # enabled engine from a disabled one, and cannot see the default path at
        # all. The sentinel now checks the default path as well.
        #
        # Adding `general` is a deliberate change of character: everyday queries
        # will now return academic sources. For a lab whose search exists to
        # answer technical and reference questions that is the point, and it is
        # one line to revert.
        { name = "crossref"; disabled = false;
          categories = [ "general" "science" "scientific publications" ]; }
        { name = "openalex"; disabled = false;
          categories = [ "general" "science" "scientific publications" ]; }
        { name = "wikipedia"; disabled = false; }     #  2 /  1 — narrow, correct
        { name = "wikispecies"; disabled = false; }   #  5 / 10
        { name = "wikidata"; disabled = false; }      #  0 — no match, reported cleanly
        { name = "arxiv"; disabled = false; }         #  0 — no match, reported cleanly
        { name = "pubmed"; disabled = false; }        # 20 /  0 — honest: a medical
                                                      # corpus has no Nothofagus
      ];

      # ⚠️ WHAT THIS INSTANCE IS NOW GOOD AT HAS CHANGED, and pretending
      # otherwise is how a consumer gets surprised. It answers technical,
      # scientific and reference questions well and GENERAL WEB QUESTIONS NOT AT
      # ALL. If general web search is needed, the root-cause fix is an API key
      # (Brave Search API, Azure, Tavily, Exa) — SearXNG supports key-based
      # engines, and buying one stops this host being a scraper. Anything else
      # is cat-and-mouse with a party that has already decided the answer.
    };
  };

  # Generate the SearXNG secret key out of band (persisted, never committed).
  systemd.services.searx-secret-key = {
    description = "Generate SearXNG secret key (off-git)";
    wantedBy = [ "multi-user.target" ];
    before = [ "searx-init.service" "uwsgi.service" "searx.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0750 /var/lib/searx-secret
      f=/var/lib/searx-secret/secret.env
      if [ ! -s "$f" ]; then
        printf 'SEARX_SECRET_KEY=%s\n' "$(${pkgs.openssl}/bin/openssl rand -hex 32)" > "$f"
        chmod 0600 "$f"
      fi
    '';
  };
}
