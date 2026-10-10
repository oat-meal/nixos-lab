# NordVPN Setup Guide (wgnord)

> **STATUS: SETUP NEVER COMPLETED — this is a guide, not a description of a working system.**
> Last verified 2026-07-08. The Nix side is deployed (`nordvpn.nix` is imported by
> **workstation-nixos and laptop-nixos**), but no access token was ever configured, so nothing
> has actually connected. Treat the steps below as untested against the current deployment.
>
> **Unfinished work is parked, not lost.** A larger rewrite — a `wgnord` config template plus a
> `nordvpn` `writeShellApplication` with profile management — was in progress on the laptop
> (2026-08-11) and is **stashed** there (message "nordvpn WIP 2026-08-11 — unfinished,
> non-working (parked 2026-08-16)"; find it with `git stash list` — it is not `stash@{0}`).
> It was parked 2026-08-16 to keep builds clean and consistent. Recover with
> `git stash pop stash@{N}` on laptop-nixos before starting fresh, or `git stash drop stash@{N}`
> to discard.
>
> Note `nordvpn.nix` is a **shared** module: changes land on two hosts. Test on one first
> (postmortem action item #5).

## What is actually deployed
- ✅ `wgnord` + WireGuard tools installed
- ✅ Firewall configured (`wgnord` trusted, NM leaves the interface unmanaged)
- ✅ A basic `nordvpn` helper script (connect / disconnect / status wrapper around `wgnord`)
- ❌ **No access token configured — never connected**

## Step 1: Get Your NordVPN Access Token

1. Go to: https://my.nordaccount.com/dashboard/nordvpn/access-tokens
2. Log in with your NordVPN account
3. Click "Generate new token"
4. Give it a name (e.g., "NixOS Desktop")
5. Copy the token (you'll only see it once!)

## Step 2: Configure wgnord with Your Token

After rebuilding your system, run:

```bash
# Store your NordVPN access token
sudo wgnord login <YOUR_ACCESS_TOKEN>
```

## Step 3: Connect to NordVPN

### Basic Connection

```bash
# Connect to fastest server
nordvpn connect us

# Connect to specific country
nordvpn connect uk
nordvpn connect ca
nordvpn connect de
```

### Check Status

```bash
# View connection status
nordvpn status

# Show WireGuard details
sudo wg show
```

### Disconnect

```bash
nordvpn disconnect
```

## Advanced Usage

### Direct wgnord Commands

wgnord 0.2.1 has only `login`, `connect`, `disconnect` and `account` (no server listing, no
`logout`, no `--technology` flag — it is always WireGuard/NordLynx):

```bash
# Connect to a country
sudo wgnord connect us

# Show account info
sudo wgnord account

# Show help
wgnord --help
```

### VPN Kill Switch (Optional)

If you want to prevent all internet traffic when VPN is disconnected, edit `/etc/nixos/hosts/common/optional/networking/nordvpn.nix` and uncomment the "VPN Kill Switch" section at the bottom.

**Warning**: With kill switch enabled, you won't have internet unless VPN is connected. Good for privacy, but can break things if VPN disconnects unexpectedly.

## Gaming with VPN

### Performance Tips

1. **Choose nearby servers**: Lower latency for gaming
   ```bash
   nordvpn connect us  # If you're in North America
   ```

2. **Use NordLynx protocol**: Already configured (WireGuard-based, fastest)

3. **Check latency before gaming**:
   ```bash
   ping -c 5 google.com
   ```

### Steam Remote Play with VPN

Steam Remote Play ports are already configured to work through the VPN. If you have connection issues:

NixOS uses a declarative firewall (iptables backend here; `networking.nftables.enable = false`),
not firewalld. If Steam Remote Play needs
extra ports, add them to `networking.firewall.allowedTCPPorts` / `.allowedUDPPorts` and
rebuild — there is no runtime `firewall-cmd`.

## Troubleshooting

### "Connection failed" error

```bash
# Check if WireGuard module is loaded
lsmod | grep wireguard

# Restart NetworkManager
sudo systemctl restart NetworkManager
```

### DNS not working

```bash
# Check DNS resolution
resolvectl status

# Manually set DNS (if needed)
sudo resolvectl dns wgnord 103.86.96.100 103.86.99.100
```

### Can't authenticate

```bash
# Re-login with token (there is no logout command; login overwrites the stored token)
sudo wgnord login <YOUR_TOKEN>
```

### VPN connected but no internet

```bash
# Check routing
ip route show

# Check firewall
sudo nft list ruleset | grep wgnord
```

## Security Notes

- **Firewall is now enabled**: This blocks unwanted incoming connections
- **Steam ports**: Still open for Remote Play (local network only)
- **VPN traffic**: Encrypted via WireGuard (NordLynx)
- **DNS**: Configured to use NordVPN's DNS servers when connected

## Quick Reference

| Command | Action |
|---------|--------|
| `nordvpn connect us` | Connect to US server |
| `nordvpn disconnect` | Disconnect from VPN |
| `nordvpn status` | Show connection status |
| `sudo wg show` | Show WireGuard details |

## Next Steps

1. Rebuild your system: `sudo nixos-rebuild switch --flake /etc/nixos#workstation-nixos`
2. Get your access token from NordVPN dashboard
3. Run: `sudo wgnord login <TOKEN>`
4. Connect: `nordvpn connect us`
5. Test: `curl ifconfig.me` (should show VPN IP)

## Configuration Files

- `/etc/nixos/hosts/common/optional/networking/nordvpn.nix` — WireGuard VPN, firewall, and the `nordvpn` helper alias
