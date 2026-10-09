"""Host Health MCP Server — local system health tools for Claude Code."""

import asyncio
import json
import os
import re
import subprocess
import time
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("host-health")


def run(cmd: list[str], timeout: int = 10) -> str:
    """Run a command and return stdout, or an error string."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() or r.stderr.strip()
    except subprocess.TimeoutExpired:
        return f"ERROR: command timed out after {timeout}s"
    except FileNotFoundError:
        return f"ERROR: {cmd[0]} not found"


@mcp.tool()
def pool_status() -> str:
    """Get ZFS pool health, capacity, and last scrub status for all pools."""
    lines = []

    pool_list = run(["zpool", "list", "-H", "-o", "name,size,alloc,free,cap,health"])
    if pool_list.startswith("ERROR"):
        return pool_list
    lines.append("POOL        SIZE   ALLOC   FREE    CAP  HEALTH")
    lines.append(pool_list)
    lines.append("")

    pools = [line.split()[0] for line in pool_list.splitlines() if line.strip()]
    for pool in pools:
        status = run(["zpool", "status", pool])
        for sline in status.splitlines():
            stripped = sline.strip()
            if stripped.startswith("scan:") or stripped.startswith("scrub"):
                lines.append(f"{pool} scrub: {stripped}")
                break
        for sline in status.splitlines():
            stripped = sline.strip()
            if stripped.startswith("errors:"):
                lines.append(f"{pool} errors: {stripped}")
                break

    return "\n".join(lines)


@mcp.tool()
def service_status(services: list[str] | None = None) -> str:
    """Check systemd service status. Defaults to key infrastructure services.

    Args:
        services: Optional list of service names to check. Defaults to
                  wireguard, sshd, syncthing, fail2ban, zfs targets.
    """
    if services is None:
        services = [
            "wireguard-wg0.service",
            "sshd.service",
            "syncthing.service",
            "fail2ban.service",
            "zfs-scrub-weekly.timer",
            "zfs-auto-snapshot-hourly.timer",
        ]

    lines = []
    for svc in services:
        raw = run(["systemctl", "is-active", svc])
        state = raw.splitlines()[0] if raw else "unknown"
        lines.append(f"{svc}: {state}")

    failed = run(["systemctl", "--failed", "--no-legend", "--no-pager"])
    if failed:
        lines.append("")
        lines.append("FAILED UNITS:")
        lines.append(failed)
    else:
        lines.append("")
        lines.append("No failed units.")

    return "\n".join(lines)


@mcp.tool()
def journal_errors(since: str = "24h ago", priority: str = "err", limit: int = 50) -> str:
    """Get recent journal errors/warnings.

    Args:
        since: Time window (e.g. "1h ago", "24h ago", "today"). Default: 24h ago.
        priority: Minimum priority level (emerg, alert, crit, err, warning). Default: err.
        limit: Maximum number of lines to return. Default: 50.
    """
    raw = run(
        [
            "journalctl",
            f"--since={since}",
            f"--priority={priority}",
            "--no-pager",
            f"--lines={limit}",
            "--output=short-precise",
        ],
        timeout=15,
    )
    if not raw or "No entries" in raw or raw.startswith("ERROR"):
        return raw or "No journal entries matching criteria."
    return raw


@mcp.tool()
def ollama_models() -> str:
    """List models available in Ollama with their sizes."""
    raw = run(["ollama", "list"], timeout=15)
    if raw.startswith("ERROR"):
        return raw
    return raw or "No models installed."


@mcp.tool()
def disk_usage() -> str:
    """Get disk usage for all ZFS datasets and key mount points."""
    zfs = run(["zfs", "list", "-o", "name,used,avail,refer,mountpoint"])
    return zfs


# ---------------------------------------------------------------------------
# Fleet tools — fan out across the wg0 mesh. The MCP runs on the server, so
# "server" is local (sh -c); workstation/laptop are reached as oat@<wg0-ip>.
# Read-only. Unreachable hosts (e.g. a powered-off laptop) degrade gracefully.
# ---------------------------------------------------------------------------

HOSTS = {"server": None, "workstation": "10.100.0.1", "laptop": "10.100.0.3"}
SYS_PATH = "/run/current-system/sw/bin"
# Remote probes log in as lab-monitor (no wheel, journal group only) with a key that
# is authorized nowhere else, so a compromised server is not oat on the other hosts.
MONITOR_KEY = os.environ.get("LAB_MONITOR_KEY", os.path.expanduser("~/.ssh/lab_monitor"))
_ESC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]")


def _clean(s: str) -> str:
    """Strip ANSI/OSC escapes (the mesh shells inject terminal color codes over ssh)."""
    return _ESC.sub("", s)


def run_on(host_ip, shell_cmd: str, timeout: int = 12) -> str:
    """Run a shell command locally (host_ip is None) or on a remote wg0 host via ssh.

    Prepends the NixOS system PATH so tools resolve in a non-login session; remote
    uses key-only auth and auto-accepts first-seen host keys (private wg0 mesh).
    """
    full = f"export PATH={SYS_PATH}:$PATH; {shell_cmd}"
    if host_ip is None:
        return _clean(run(["sh", "-c", full], timeout=timeout))
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "StrictHostKeyChecking=accept-new",
           "-o", "IdentitiesOnly=yes", "-i", MONITOR_KEY, f"lab-monitor@{host_ip}", full]
    return _clean(run(ssh, timeout=timeout + 5))


def _unreachable(raw: str) -> bool:
    low = raw.lower()
    return (raw.startswith("ERROR") or "verification failed" in low
            or "timed out" in low or "connection refused" in low
            or "no route to host" in low or "could not resolve" in low
            or "permission denied" in low)


def _sections(raw: str) -> dict:
    secs, cur = {}, None
    for line in raw.splitlines():
        m = re.match(r"^@@@(\w+)@@@$", line.strip())
        if m:
            cur = m.group(1)
            secs[cur] = []
        elif cur is not None:
            secs[cur].append(line)
    return secs


def _first(secs: dict, key: str) -> str:
    return next((x.strip() for x in secs.get(key, []) if x.strip()), "")


@mcp.tool()
def fleet_health(hosts: list[str] | None = None) -> str:
    """Health snapshot across the wg0 fleet (server, workstation, laptop).

    One ssh round-trip per host gathers: uptime, failed systemd units, root and
    /storage disk usage, ZFS pool health, and the current system generation.
    Unreachable hosts (e.g. a powered-off laptop) are reported as such. Returns
    JSON keyed by host — structured for later LLM triage. Read-only.

    Args:
        hosts: optional subset, e.g. ["server", "workstation"]. Default: all.
    """
    # Markers use @@@ (not ===): the remote login shell is zsh, whose EQUALS
    # expansion would try to run a leading "===HOST===" as a command.
    script = (
        "echo @@@HOST@@@; hostname; "
        "echo @@@UP@@@; awk '{s=$1; printf \"%dd %dh %dm\\n\", s/86400, s%86400/3600, s%3600/60}' /proc/uptime 2>/dev/null; "
        "echo @@@FAILED@@@; systemctl --failed --no-legend --no-pager 2>/dev/null; "
        "echo @@@DISK@@@; df -h --output=target,pcent / /storage 2>/dev/null | tail -n +2; "
        "echo @@@ZFS@@@; zpool list -H -o name,cap,health 2>/dev/null; "
        "echo @@@GEN@@@; readlink -f /run/current-system 2>/dev/null | sed 's#.*/##'"
    )
    out = {}
    for h in (hosts or list(HOSTS)):
        if h not in HOSTS:
            out[h] = {"error": f"unknown host '{h}'"}
            continue
        raw = run_on(HOSTS[h], script, timeout=12)
        if _unreachable(raw):
            out[h] = {"reachable": False, "detail": raw.strip()[:200]}
            continue
        s = _sections(raw)
        failed = [l.strip() for l in s.get("FAILED", []) if l.strip()]
        out[h] = {
            "reachable": True,
            "hostname": _first(s, "HOST"),
            "uptime": _first(s, "UP"),
            "failed_count": len(failed),
            "failed_units": failed,
            "disk": [l.strip() for l in s.get("DISK", []) if l.strip()],
            "zfs": [l.strip() for l in s.get("ZFS", []) if l.strip()],
            "generation": _first(s, "GEN"),
        }
    return json.dumps(out, indent=2)


@mcp.tool()
def fleet_service_status(services: list[str] | None = None,
                         hosts: list[str] | None = None) -> str:
    """systemd service state across the wg0 fleet (one block per host).

    Args:
        services: services to check on each host. Default: mesh essentials
                  (wireguard-wg0, sshd, syncthing, fail2ban).
        hosts: optional subset. Default: all.
    """
    svcs = services or ["wireguard-wg0.service", "sshd.service",
                        "syncthing.service", "fail2ban.service"]
    script = (
        "for s in " + " ".join(svcs) + "; do "
        'echo "$s: $(systemctl is-active "$s" 2>/dev/null)"; done; '
        'f=$(systemctl --failed --no-legend --no-pager 2>/dev/null); '
        '[ -n "$f" ] && { echo "-- failed units --"; echo "$f"; } || echo "-- no failed units --"'
    )
    blocks = []
    for h in (hosts or list(HOSTS)):
        if h not in HOSTS:
            blocks.append(f"## {h}\nunknown host")
            continue
        raw = run_on(HOSTS[h], script, timeout=12)
        body = f"UNREACHABLE: {raw.strip()[:120]}" if _unreachable(raw) else raw.strip()
        blocks.append(f"## {h}\n{body}")
    return "\n\n".join(blocks)


@mcp.tool()
def fleet_journal_errors(since: str = "24h ago", priority: str = "err",
                         limit: int = 30, hosts: list[str] | None = None) -> str:
    """Recent journal errors across the wg0 fleet (one block per host).

    NOTE: full system-journal access on a remote host requires the `oat` user to be
    in that host's `systemd-journal` group (currently only guaranteed on the server).

    Args:
        since: window, e.g. "1h ago", "today". Default: "24h ago".
        priority: minimum level (emerg..warning). Default: err.
        limit: max lines per host. Default: 30.
        hosts: optional subset. Default: all.
    """
    script = (f'journalctl --since="{since}" --priority={priority} --no-pager '
              f'--lines={limit} --output=short-precise 2>/dev/null')
    blocks = []
    for h in (hosts or list(HOSTS)):
        if h not in HOSTS:
            blocks.append(f"## {h}\nunknown host")
            continue
        raw = run_on(HOSTS[h], script, timeout=20)
        if _unreachable(raw):
            body = f"UNREACHABLE: {raw.strip()[:120]}"
        else:
            body = raw.strip() or "No entries matching criteria."
        blocks.append(f"## {h}\n{body}")
    return "\n\n".join(blocks)


@mcp.tool()
def backup_status() -> str:
    """Backup integrity across the wg0 fleet (ZFS-snapshot based).

    For each ZFS dataset marked for auto-snapshot (com.sun:auto-snapshot=true),
    reports its newest snapshot and how long ago it was taken. Flags datasets with
    NO snapshots (backups not running) or a stale newest (>2h — the timer may have
    stalled). Read-only. Also notes the last scrub per pool.
    """
    now = time.time()
    props_cmd = "zfs get -H -t filesystem -o name,value com.sun:auto-snapshot 2>/dev/null"
    snaps_cmd = "zfs list -t snapshot -H -p -o name,creation 2>/dev/null"
    scrub_cmd = "zpool status 2>/dev/null | grep 'scan:'"
    blocks = []
    for h, ip in HOSTS.items():
        props = run_on(ip, props_cmd)
        if _unreachable(props):
            if h == "laptop":
                continue
            blocks.append(f"## {h}\nUNREACHABLE: {props.strip()[:100]}")
            continue
        datasets = [l.split("\t")[0] for l in props.splitlines()
                    if "\t" in l and l.rsplit("\t", 1)[-1] == "true"]
        lines = [f"## {h}"]
        if not datasets:
            lines.append("  (no datasets marked for auto-snapshot)")
        else:
            newest = {}
            for l in run_on(ip, snaps_cmd).splitlines():
                p = l.split("\t")
                if len(p) >= 2 and "@" in p[0]:
                    ds = p[0].split("@", 1)[0]
                    try:
                        cr = int(p[1])
                    except ValueError:
                        continue
                    if cr > newest.get(ds, 0):
                        newest[ds] = cr
            for ds in datasets:
                cr = newest.get(ds)
                if not cr:
                    lines.append(f"  {ds}: NO SNAPSHOTS — backups not running!")
                else:
                    age = (now - cr) / 3600
                    lines.append(f"  {ds}: newest {age:.1f}h ago" + (" (STALE!)" if age > 2 else ""))
        scrub = run_on(ip, scrub_cmd)
        if scrub and not _unreachable(scrub):
            lines.append(f"  scrub: {scrub.strip().replace(chr(10), '; ')[:160]}")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


@mcp.tool()
def flake_status() -> str:
    """Flake input freshness — for each direct input in /etc/nixos/flake.lock, how
    many days since it was last updated (higher = more stale). Read-only. The weekly
    update-advisor report has a full risk briefing on what updating would change.
    """
    try:
        lock = json.loads(open("/etc/nixos/flake.lock").read())
    except OSError as e:
        return f"ERROR: {e}"
    root = lock["nodes"][lock["root"]].get("inputs", {})
    lines = ["input                 age (days since last update)"]
    for name, ref in sorted(root.items()):
        nn = ref if isinstance(ref, str) else ref[0]
        lm = lock["nodes"].get(nn, {}).get("locked", {}).get("lastModified", 0)
        age = int((time.time() - lm) / 86400) if lm else None
        lines.append(f"{name:<20}  {age if age is not None else '?'}")
    return "\n".join(lines)


@mcp.tool()
def zfs_snapshots(dataset: str = "", limit: int = 25) -> str:
    """List ZFS snapshots on the server (newest first) with space used + creation
    time. Optionally filter to a dataset (e.g. 'rpool/storage/git'). Read-only.

    To recover a file, browse the snapshot's `.zfs/snapshot/<snap>/` directory under
    the dataset's mountpoint and copy the file back out — this tool never modifies
    anything.

    Args:
        dataset: optional dataset to filter (recursive). Default: all.
        limit: max snapshots to list. Default 25.
    """
    base = "zfs list -t snapshot -o name,used,creation -S creation -H"
    cmd = (f"{base} -r {dataset}" if dataset else base) + " 2>/dev/null"
    raw = run_on(None, cmd)
    if raw.startswith("ERROR"):
        return raw
    snaps = [l for l in raw.splitlines() if "@" in l][:limit]
    if not snaps:
        return f"No snapshots found{(' for ' + dataset) if dataset else ''}."
    out = ["SNAPSHOT\tUSED\tCREATED", *snaps, "",
           "Recover a file: cp <dataset-mountpoint>/.zfs/snapshot/<snap>/<relpath> <dest>"]
    return "\n".join(out)


if __name__ == "__main__":
    mcp.run(transport="stdio")
