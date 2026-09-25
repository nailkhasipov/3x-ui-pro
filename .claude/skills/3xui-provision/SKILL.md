---
name: 3xui-provision
description: Provision or re-provision a VPN server with this repo's x-ui-latest.sh installer (3x-ui panel + nginx SNI routing + Let's Encrypt + Clash subscription + diagnostics). Covers preflight checks, DNS validation, running the installer so it survives SSH drops, and verifying the result end to end. Use this whenever the user wants to set up, install, reinstall, patch or troubleshoot a 3x-ui-pro server, mentions x-ui-latest.sh / x-ui-patch.sh, gives you a server IP and asks to "set up the panel", or reports that a fresh install misbehaves — even if they do not name the script.
---

# Provisioning a 3x-ui-pro server

The installer is a single script run as root on a fresh VPS. It is unattended once
it has both domains, so most of the work is making sure the preconditions hold —
a failed run leaves a half-configured box that is easier to reinstall than repair.

## What the installer needs before it will succeed

Check all of these before running anything. `scripts/preflight.sh` runs them in one pass.

| Requirement | Why it matters |
|---|---|
| Ubuntu 24.04 / 26.04 or Debian 12 / 13 | `check_os` hard-exits on anything else |
| CPU is not QEMU-emulated | `check_cpu` hard-exits; ask the host for `host-passthrough` |
| Two **different** domains, both A-records to the server IP | Panel domain and REALITY domain; identical values abort the run |
| Cloudflare proxy **off** (grey cloud) | certbot runs standalone on :80; REALITY cannot survive proxying |
| Ports 80 and 443 free | certbot standalone binds :80 |
| Root SSH | the script refuses to run as non-root |

Resolve the domains **from the server**, not from your laptop — split-horizon DNS
and local caches lie:

```bash
ssh root@$IP 'getent ahostsv4 panel.example.com | head -1'
```

If the answer is a Cloudflare address (104.x, 172.67.x) rather than the server IP,
the proxy is still on and certbot will fail.

## Running it

Run detached. A dropped SSH session mid-install leaves nginx stopped and no certs,
which means starting over:

```bash
ssh root@$IP 'cd /root && \
  wget -qO x-ui-latest.sh https://raw.githubusercontent.com/nailkhasipov/3x-ui-pro/main/x-ui-latest.sh && \
  setsid nohup bash x-ui-latest.sh \
    -subdomain panel.example.com \
    -reality_domain cdn.example.com \
    < /dev/null > /root/x-ui-install.log 2>&1 &'
```

With both `-subdomain` and `-reality_domain` supplied the script never prompts, so
there is nothing to babysit. Poll for completion by watching for the process to
exit rather than tailing the log:

```bash
ssh root@$IP 'pgrep -f "[x]-ui-latest\.sh" >/dev/null' || echo done
```

The bracket trick in `[x]-ui-latest` stops `pgrep` from matching its own command line.

Assets (fake sites, Clash template, diagnostics) are fetched from the repo's raw
GitHub URL at install time, so **local edits only reach servers after a push to
`main`**. If you changed the installer and want to test it, push first, or the
server will silently run the old version. Comparing checksums catches this:

```bash
ssh root@$IP 'sha256sum /root/x-ui-latest.sh' ; sha256sum x-ui-latest.sh
```

## Verifying the result

**A server-side check cannot tell you the server is usable.** Everything below runs
on the box itself — the tunnel test even loops back to the same machine — so it
answers "is this configured correctly", never "can the user reach it". A server
whose IP is blocked by the user's ISP passes every one of these checks with a clean
green report. Treat this section as necessary but not sufficient, and finish with
the client-side acceptance step further down before handing out any keys.

`scripts/verify-install.sh` checks services, certs, `nginx -t`, inbounds, UFW, BBR
and external reachability. Two checks matter more than the rest because they fail
silently:

**REALITY SNI routing** — the stream block routes by SNI, so a handshake using the
REALITY domain's name against the panel address must return the REALITY domain's cert:

```bash
openssl s_client -connect panel.example.com:443 -servername cdn.example.com </dev/null 2>&1 \
  | grep -E 'subject=|Verify return code'
```

Expect `subject=CN=cdn.example.com` and `Verify return code: 0 (ok)`. This proves
nginx preread → xray:8443 → target 127.0.0.1:9443 is wired correctly.

**UFW did not lock you out** — the script runs `ufw disable` early and re-enables it
at the end. Confirm `22/tcp ALLOW` is present before you disconnect.

A green install still has **no clients**. The installer creates inbounds only;
subscriptions stay empty until someone is added. Use the `3xui-clients` skill for that.

## Acceptance: prove it works from the user's network

This is the step that decides whether the server is real. Run
`scripts/client-side-check.sh` **on the user's own machine, on the network they will
actually use, with every other VPN turned off** — a nested tunnel makes every result
meaningless. The script prints the direct egress IP first and aborts outright when
that IP is the server being tested; in every other case it can only warn, since it
has no way to know what this network's own address should be. Read that first line
before trusting anything below it.

```bash
bash scripts/client-side-check.sh <server-ip> <subscription-url>
```

It distinguishes the failure modes that matter, and they need different answers:

| Symptom | Meaning | What to do |
|---|---|---|
| ISP resolver returns a wrong IP, `1.1.1.1` returns the right one | DNS-level block | DoH on the client, or connect by IP |
| TCP opens, TLS fails with your SNI but succeeds with `www.microsoft.com` | SNI/DPI block | New domain; the IP is still good |
| No ICMP, no TCP on any port, traceroute dies upstream | **IP-level block** | Nothing on the box can fix this — the address is dead for that network |
| Everything passes, tunnel returns the server's IP | Usable | Hand out keys |

Comparing your own SNI against a neutral one **on the same IP** is the single most
informative probe: it separates "the address is blocked" from "the name is blocked".

Two failure modes of the test itself, both of which produced confident wrong answers
in practice:

- **Another VPN left on.** The tunnel then nests inside it and succeeds regardless of
  whether the server is reachable. Always check the direct egress IP first.
- **A different device on a different path.** A phone on cellular has its own
  blocklists, and iOS can move traffic to cellular even while on Wi-Fi. "It works on
  my phone" is not evidence about the laptop's network.

When a client reports that a subscription "works", confirm what the exit IP actually
is before believing it — a Clash config whose rules end in `MATCH,DIRECT` keeps the
internet working perfectly while the proxy is dead, and a second profile can quietly
serve the traffic instead.

**Check reachability before you build.** The cheapest version of this whole exercise
is to rent the address, ping it from the target network, and only then install. An
address already on a blocklist when you rent it will never work, and no amount of
configuration will change that.

## Defects to know about

The ALPN one is now fixed in this repo's installer; the other two are still shipped defaults, so every fresh server inherits them.

**1. WebSocket broken by its own ALPN — fixed in the installer.** The `hosts` row
for the ws inbound used to be written with `alpn=["h2","http/1.1"]`. A client that
honours it negotiates h2, and a WebSocket upgrade over HTTP/2 carries no `Upgrade`
header — so the `if ($http_upgrade ~* "(WEBSOCKET|WS)")` branch in
`snippets/includes.conf` never fires and the connection dies. The symptom is subtle:
REALITY and trojan work, ws silently does not.

Servers built before the fix still carry the bad value, and `verify-install.sh`
flags them. Repair an existing install with:

```bash
sqlite3 /etc/x-ui/x-ui.db "UPDATE hosts SET alpn='[\"http/1.1\"]' WHERE remark='ws';"
x-ui restart
```

Leave trojan-gRPC on `["h2","http/1.1"]` — gRPC requires h2.

**2. The stream block has no `proxy_timeout`.** nginx defaults to 10 minutes of
idle for `ngx_stream_proxy_module`, and *all* protocols traverse this block on
:443 — so the generous `proxy_read_timeout 1d` on the HTTP locations is overridden
by it for anything arriving on 443. Whether 10 minutes is short enough to bother a
given user depends on their traffic, so treat this as a likely contributor to
"drops after a while" rather than a proven cause. Setting it explicitly is cheap:

```nginx
server {
    proxy_timeout 1h;
    ...
}
```

**3. Idle connections die after 5 minutes.** The panel ships a `policy.levels["0"]`
containing only stats counters and no `connIdle`, so Xray's default of **300 seconds**
applies: any tunnelled connection idle for five minutes is closed. Short-lived HTTP
traffic never notices, but anything long-lived and quiet — a messenger's push
connection, an SSH session, a websocket — drops.

Be precise about the symptom before reaching for this. `connIdle` only ever closes
connections that are **idle**, so it cannot explain a drop that happens mid-stream:
if the user was watching video or downloading when it broke, this is the wrong
lead and raising it will waste a round trip. Ask whether the drop happens while
traffic is flowing or only after a quiet spell, and let that decide.

This is measurable rather than theoretical: hold an idle TCP connection through the
tunnel and it closes at exactly 5m00s. The panel exposes the knob under
Xray → connection limits; leaving it empty means "use Xray's default".

The template lives in `settings.xrayTemplateConfig`, which is absent on a fresh
install (the panel falls back to a built-in default). Fetch that default, add the
policy, store it, restart:

```bash
curl -sk -b "$JAR" "$B/panel/api/setting/getDefaultJsonConfig" -H "X-CSRF-Token: $TOK" \
  | jq 'if type=="object" and has("obj") then (if (.obj|type)=="string" then (.obj|fromjson) else .obj end) else . end' \
  | jq '.policy.levels["0"] += {connIdle:1800, handshake:4, uplinkOnly:2, downlinkOnly:5}' \
  > /tmp/tpl.json
sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings WHERE key='xrayTemplateConfig';
  INSERT INTO settings (key,value) VALUES ('xrayTemplateConfig', readfile('/tmp/tpl.json'));"
x-ui restart
```

Confirm it took effect in the generated config, not just the database:

```bash
jq -c '.policy.levels["0"]' /usr/local/x-ui/bin/config.json
```

1800s suits a personal server. Lower it on a busy one — idle connections hold memory
and file descriptors.

## The XHTTP inbound ships disabled

The installer creates four inbounds but writes the XHTTP one with `enable=0`, so it
is never handed to clients and never appears in a subscription. That is the shipped
behaviour, not a mistake in your install — but XHTTP over H2/H3 is often the most
resilient transport where DPI is aggressive, so it is worth deciding deliberately
rather than inheriting the default. Enabling it is a toggle in the panel; the client
scripts pick up whatever is enabled, and both link parsers understand `type=xhttp`.

## Measuring an idle timeout without fooling yourself

Three traps make idle-timeout tests report the wrong number, and each one produced a
confident but wrong answer before being caught:

- **sshd** closes unauthenticated sessions at `LoginGraceTime` (120s default), so
  holding an idle connection to port 22 measures sshd.
- **Xray blocks `geoip:private`**, so a probe aimed at `127.0.0.1` is blackholed
  instantly and looks like a dead tunnel.
- **Any `x-ui restart` kills every live connection**, so running other work during a
  probe silently truncates it.

Use a target that accepts TCP and then stays silent forever, reachable at a public
address, and leave the panel alone while the probe runs.

## Housekeeping to mention to the user

- `/root/x-ui-install.log` holds the panel login and password in plaintext. Tell
  them to save the credentials and delete it.
- `x-ui-patch.sh` and `x-ui-adguard.sh` both regenerate the panel vhost. Running
  either one drops the AdGuard include, so re-run the AdGuard script afterwards.
- A daily cron does `x-ui restart`, which drops every live connection once a day.
  Worth naming if the user reports a regular disconnect.
- 1 GB VPSes ship without swap here. Nothing in the install needs it, but xray is
  the first thing the OOM killer takes. Offer a 2 GB swapfile; do not add it unasked.
