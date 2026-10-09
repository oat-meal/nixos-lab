#!/usr/bin/env python3
"""Fleet Health Sentinel — collect wg0 fleet health, triage it, emit a
severity-ranked report. READ-ONLY: it only inspects and reports; it never
changes anything. Meant to run on the server via a systemd timer.

Design: severities are assigned DETERMINISTICALLY in code (LLMs are unreliable at
numeric threshold comparisons). A local LLM is used only for what it is good at —
dropping findings explained by known-states, writing a summary, and suggesting a
read-only diagnostic command per finding. When there are no candidate findings, the
LLM is skipped entirely.

Collection mirrors ai-lab/mcp/host-health/server.py fleet_health, duplicated here
so the sentinel stays stdlib-only (no MCP dependency).

Env: OLLAMA_HOST_URL, SENTINEL_MODEL, KNOWN_STATES, SENTINEL_REPORT, NTFY_URL.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

HOSTS = {"server": None, "workstation": "10.100.0.1", "laptop": "10.100.0.3"}
SYS_PATH = "/run/current-system/sw/bin"
OLLAMA = os.environ.get("OLLAMA_HOST_URL", "http://10.100.0.2:11434")
MODEL = os.environ.get("SENTINEL_MODEL", "qwen3:30b-a3b")
KNOWN_STATES = os.environ.get("KNOWN_STATES", "/etc/nixos/docs/audit/known-states.md")
REPORT = os.environ.get("SENTINEL_REPORT", "/var/lib/fleet-sentinel/latest.md")
NTFY = os.environ.get("NTFY_URL", "")
DISK_WARN, DISK_CRIT = 85, 95
# Remote probes log in as lab-monitor (no wheel, journal group only) with a key that
# is authorized nowhere else, so a compromised server is not oat on the other hosts.
MONITOR_KEY = os.environ.get("LAB_MONITOR_KEY", os.path.expanduser("~/.ssh/lab_monitor"))
_ESC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]")


def _clean(s: str) -> str:
    return _ESC.sub("", s)


def run_on(ip, shell_cmd: str, timeout: int = 12) -> str:
    """Run locally (ip is None) or on a remote wg0 host via ssh (key-only)."""
    full = f"export PATH={SYS_PATH}:$PATH; {shell_cmd}"
    if ip is None:
        argv = ["sh", "-c", full]
    else:
        argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "IdentitiesOnly=yes", "-i", MONITOR_KEY, f"lab-monitor@{ip}", full]
        timeout += 5
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return _clean(r.stdout.strip() or r.stderr.strip())
    except subprocess.TimeoutExpired:
        return "ERROR: timed out"


def collect() -> dict:
    # @@@ markers (not ===): remote login shell is zsh, whose = expansion breaks ===X===.
    script = (
        "echo @@@HOST@@@; hostname; "
        "echo @@@UP@@@; awk '{s=$1; printf \"%dd %dh %dm\\n\", s/86400, s%86400/3600, s%3600/60}' /proc/uptime 2>/dev/null; "
        "echo @@@FAILED@@@; systemctl --failed --no-legend --no-pager 2>/dev/null; "
        "echo @@@DISK@@@; df -h --output=target,pcent / /storage 2>/dev/null | tail -n +2; "
        "echo @@@ZFS@@@; zpool list -H -o name,cap,health 2>/dev/null; "
        "echo @@@GEN@@@; readlink -f /run/current-system 2>/dev/null | sed 's#.*/##'; "
        "echo @@@SNAPPROPS@@@; zfs get -H -t filesystem -o name,value com.sun:auto-snapshot 2>/dev/null; "
        "echo @@@SNAPS@@@; zfs list -t snapshot -H -p -o name,creation 2>/dev/null; "
        "echo @@@JOURNAL@@@; journalctl -p err --since '24 hours ago' --no-pager -o short 2>/dev/null "
        "| grep -avE 'split.lock|pulseaudio|gkr-pam|MES arb|amdgpu|pidns|gtk_widget_get_scale' | tail -12"
    )
    # Hosts are probed in parallel. Serially, one sleeping laptop costs its
    # whole ConnectTimeout before the next host is even tried, so the run takes
    # the SUM of the failures rather than the slowest one. That was tolerable
    # for a nightly timer and is not for the on-demand `--collect` path, which
    # a person waits on.
    with ThreadPoolExecutor(max_workers=max(1, len(HOSTS))) as pool:
        raws = dict(zip(HOSTS, pool.map(lambda ip: run_on(ip, script), HOSTS.values())))

    out = {}
    for h, raw in raws.items():
        low = raw.lower()
        if raw.startswith("ERROR") or any(x in low for x in (
                "verification failed", "timed out", "refused", "no route",
                "could not resolve", "permission denied")):
            out[h] = {"reachable": False, "detail": raw[:200]}
            continue
        secs, cur = {}, None
        for line in raw.splitlines():
            m = re.match(r"^@@@(\w+)@@@$", line.strip())
            if m:
                cur = m.group(1)
                secs[cur] = []
            elif cur is not None:
                secs[cur].append(line)

        def first(key):
            return next((x.strip() for x in secs.get(key, []) if x.strip()), "")

        failed = [l.strip() for l in secs.get("FAILED", []) if l.strip()]
        out[h] = {
            "reachable": True,
            "hostname": first("HOST"),
            "uptime": first("UP"),
            "failed_count": len(failed),
            "failed_units": failed,
            "disk": [l.strip() for l in secs.get("DISK", []) if l.strip()],
            "zfs": [l.strip() for l in secs.get("ZFS", []) if l.strip()],
            "generation": first("GEN"),
            "journal_errors": [l.strip() for l in secs.get("JOURNAL", []) if l.strip()],
            "autosnap_datasets": [l.split("\t")[0] for l in secs.get("SNAPPROPS", [])
                                  if "\t" in l and l.rsplit("\t", 1)[-1] == "true"],
            "snap_newest": _newest_snaps(secs.get("SNAPS", [])),
        }
    return out


def _newest_snaps(lines: list) -> dict:
    """{dataset: newest snapshot creation epoch} from `zfs list -t snapshot -p`."""
    newest = {}
    for l in lines:
        p = l.split("\t")
        if len(p) >= 2 and "@" in p[0]:
            ds = p[0].split("@", 1)[0]
            try:
                cr = int(p[1])
            except ValueError:
                continue
            if cr > newest.get(ds, 0):
                newest[ds] = cr
    return newest


def _pct(token: str) -> int | None:
    try:
        return int(token.rstrip("%"))
    except ValueError:
        return None


def analyze(health: dict) -> list:
    """Deterministic candidate findings with correct severities (no LLM)."""
    findings = []

    def add(host, sev, text):
        findings.append({"host": host, "severity": sev, "finding": text})

    for h, v in health.items():
        if not v.get("reachable", False):
            if h == "laptop":
                continue  # expected — the laptop powers off
            add(h, "critical", f"host unreachable over wg0 ({v.get('detail', '')[:80]})")
            continue
        for u in v.get("failed_units", []):
            add(h, "warning", f"failed systemd unit: {u}")
        for d in v.get("disk", []):
            parts = d.split()
            if len(parts) >= 2 and (pct := _pct(parts[-1])) is not None:
                if pct > DISK_CRIT:
                    add(h, "critical", f"disk {parts[0]} at {pct}% used")
                elif pct > DISK_WARN:
                    add(h, "warning", f"disk {parts[0]} at {pct}% used")
        for z in v.get("zfs", []):
            parts = z.split()
            if len(parts) >= 3:
                name, cap, hlth = parts[0], _pct(parts[1]), parts[2].upper()
                if hlth != "ONLINE":
                    add(h, "critical", f"ZFS pool {name} health={parts[2]}")
                elif cap is not None and cap > DISK_CRIT:
                    add(h, "critical", f"ZFS pool {name} at {cap}% capacity")
                elif cap is not None and cap > DISK_WARN:
                    add(h, "warning", f"ZFS pool {name} at {cap}% capacity")
        # backup integrity: a dataset marked for auto-snapshot must have recent snapshots
        newest = v.get("snap_newest", {})
        for ds in v.get("autosnap_datasets", []):
            cr = newest.get(ds)
            if not cr:
                add(h, "critical", f"{ds}: marked for auto-snapshot but has NO snapshots — backups are not running")
            else:
                age_h = (datetime.now().timestamp() - cr) / 3600
                if age_h > 2:
                    add(h, "warning", f"{ds}: newest snapshot is {age_h:.1f}h old — auto-snapshot may have stalled")
    return findings


ENRICH_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "actions": {"type": "array", "items": {"type": "string"}},
        "journal_findings": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "host": {"type": "string"},
                "severity": {"type": "string", "enum": ["info", "warning"]},
                "finding": {"type": "string"},
                "suggested_action": {"type": "string"},
            },
            "required": ["host", "severity", "finding", "suggested_action"],
        }},
    },
    "required": ["summary", "actions", "journal_findings"],
}

ENRICH_SYSTEM = """You are a site-reliability engineer for a personal NixOS home lab (hosts: \
server, workstation, laptop; private WireGuard mesh). You receive JSON with two parts:
1) `deterministic_findings`: findings ALREADY severity-classified by code. You must NOT add, remove, \
or re-classify them — the list is authoritative.
2) `journal_errors_by_host`: raw recent journal error lines per host. These are noisy and MOST are \
benign/transient.

Return JSON:
- `actions`: EXACTLY one entry per deterministic finding, same order — a single concrete READ-ONLY \
diagnostic command to inspect findings[i] (never destructive). If a finding clearly matches an \
expected KNOWN STATE below, prefix its action with "(likely expected) ".
- `journal_findings`: ONLY the journal errors genuinely worth attention that are NOT explained by the \
KNOWN STATES below. Omit noise, expected states, and transient/cosmetic messages. Each: {host, \
severity ("info" or "warning" ONLY — never critical), a concise finding, a read-only suggested_action}. \
If nothing in the journals is notable, return an empty array.
- `summary`: one sentence reflecting the ACTUAL overall state — do NOT say "healthy" if there are any \
warnings or criticals.

KNOWN STATES (treat matching lines/findings as expected; do not surface them):
{known_states}
"""


def enrich(candidates: list, journal_by_host: dict) -> dict:
    """LLM: annotate deterministic findings with read-only actions, triage journal
    errors against known-states into findings, and write a summary. It cannot alter
    the deterministic findings' host/severity/text."""
    try:
        known = open(KNOWN_STATES).read()
    except OSError:
        known = "(known-states file not found)"
    payload = {"deterministic_findings": candidates,
               "journal_errors_by_host": journal_by_host}
    body = {
        "model": MODEL, "stream": False, "think": False,
        # A bound, not a tuning knob. Generation was previously limited only by
        # OLLAMA_CONTEXT_LENGTH — a *global* setting this service does not own,
        # which was raised 8192 -> 32768 for an unrelated consumer on
        # 2026-08-24. `format` already constrains this particular call, so the
        # window was not in fact reachable here; the point is that relying on a
        # setting owned elsewhere for a bound is fragile even when it holds.
        # A triage verdict against a fixed schema needs nowhere near 1024.
        "format": ENRICH_SCHEMA, "options": {"temperature": 0.1, "num_predict": 1024},
        "messages": [
            {"role": "system", "content": ENRICH_SYSTEM.replace("{known_states}", known)},
            {"role": "user", "content": json.dumps(payload, indent=2)},
        ],
    }
    req = urllib.request.Request(
        OLLAMA + "/api/chat", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        resp = json.load(r)
    return json.loads(resp["message"]["content"])


def _overall(findings: list) -> str:
    sevs = {f.get("severity") for f in findings}
    if "critical" in sevs:
        return "critical"
    if "warning" in sevs:
        return "warnings"
    return "healthy"


_SEV_ORDER = {"critical": 0, "warning": 1, "info": 2}


def render(health: dict, verdict: dict, ts: str) -> str:
    status = verdict.get("overall_status", "unknown")
    lines = [f"# Fleet Health — {ts}", "",
             f"**Status:** {status.upper()}", "",
             verdict.get("summary", ""), ""]
    findings = verdict.get("findings", [])
    if findings:
        lines += ["## Findings", "",
                  "| Host | Severity | Finding | Suggested check |",
                  "|------|----------|---------|-----------------|"]
        for f in sorted(findings, key=lambda x: _SEV_ORDER.get(x.get("severity"), 3)):
            fnd = f.get("finding", "").replace("|", "\\|")
            act = f.get("suggested_action", "").replace("|", "\\|")
            lines.append(f"| {f.get('host', '?')} | {f.get('severity', '?')} | {fnd} | {act} |")
        lines.append("")
    lines += ["## Raw snapshot", "", "```json", json.dumps(health, indent=2), "```", ""]
    return "\n".join(lines)


def collect_json() -> str:
    """Deterministic collection + severity, as JSON. No LLM, no notification.

    Exists so a second consumer does not have to reimplement the checks. Two
    implementations of "is the fleet healthy" is how they drift, and the one
    that drifts is always the one nobody is watching.

    Deliberately stops before `enrich()`: severity here is decided by rule, and
    an on-demand caller wants the facts, not a nightly report's prose. It also
    must not fire ntfy — asking a question is not an incident.
    """
    health = collect()
    return json.dumps({
        "hosts": health,
        "findings": analyze(health),
        "collected_at": datetime.now().astimezone().isoformat(timespec="seconds"),
    })


def main():
    # --collect is the reuse seam. Kept to one flag rather than argparse: the
    # nightly path must stay exactly as it was.
    args = sys.argv[1:]
    if args == ["--collect"]:
        print(collect_json())
        return
    # Unknown arguments are rejected rather than ignored. Ignoring them means an
    # older binary treats a flag it does not understand as "no arguments" and
    # runs the FULL nightly job — LLM triage, report rewrite, ntfy push. That is
    # not theoretical: it happened once during development, from a caller that
    # believed it was asking a read-only question.
    if args:
        print(f"fleet-sentinel: unknown arguments: {' '.join(args)}", file=sys.stderr)
        print("usage: fleet-sentinel [--collect]", file=sys.stderr)
        raise SystemExit(2)

    ts = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    health = collect()
    candidates = analyze(health)
    journal_by_host = {h: v["journal_errors"] for h, v in health.items()
                       if v.get("journal_errors")}

    if not candidates and not any(journal_by_host.values()):
        verdict = {"overall_status": "healthy",
                   "summary": "All hosts reachable; no disk, ZFS, unit, or journal issues.",
                   "findings": []}
    else:
        # Deterministic findings are authoritative (LLM annotates only). The LLM may
        # surface journal-derived findings, but capped at <=warning and filtered by
        # known-states — it can never add/drop/reclassify the deterministic ones.
        summary, journal_findings = "", []
        try:
            enriched = enrich(candidates, journal_by_host)
            actions = enriched.get("actions", [])
            summary = enriched.get("summary", "")
            journal_findings = enriched.get("journal_findings", [])
        except Exception as e:  # degrade gracefully — never crash the timer
            actions, summary = [], f"(LLM enrichment failed: {e})"
        for i, c in enumerate(candidates):
            c["suggested_action"] = actions[i] if i < len(actions) else ""
        for jf in journal_findings:  # guardrail: journal noise is never critical
            if jf.get("severity") not in ("info", "warning"):
                jf["severity"] = "warning"
        findings = candidates + journal_findings
        verdict = {"overall_status": _overall(findings),
                   "summary": summary, "findings": findings}

    report = render(health, verdict, ts)
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    with open(REPORT, "w") as f:
        f.write(report)

    n = len(verdict.get("findings", []))
    print(f"[fleet-sentinel] {ts} status={verdict['overall_status']} findings={n} -> {REPORT}")
    for f in verdict.get("findings", []):
        print(f"  [{f.get('severity')}] {f.get('host')}: {f.get('finding')}")

    if NTFY and verdict["overall_status"] != "healthy":
        try:
            req = urllib.request.Request(
                NTFY, data=verdict.get("summary", "")[:400].encode(),
                headers={"Title": f"Fleet {verdict['overall_status']} ({n} findings)",
                         "Priority": "high" if verdict["overall_status"] == "critical" else "default"})
            urllib.request.urlopen(req, timeout=10)
        except Exception as e:
            print(f"[fleet-sentinel] ntfy push failed: {e}")


if __name__ == "__main__":
    main()
