---
name: 3xui-clients
description: Create, inspect, update and delete 3x-ui panel clients and their subscription links from the command line, via the 3x-ui 3.8.5 REST API — including UUID/password generation, per-inbound flow, Clash subscription URLs, and end-to-end tunnel verification. Use this whenever the user wants to add a user, device, key, subscription or "another link" to a 3x-ui server, asks why a subscription is empty or a client cannot connect, or wants to script client management instead of clicking through the panel. Reach for it before writing raw SQL against x-ui.db.
---

# Managing 3x-ui clients from the CLI

3x-ui 3.8.5 reworked the data model: a client is a first-class row in `clients`,
attached to inbounds through `client_inbounds`. One client therefore covers every
protocol at once — a single UUID for the VLESS inbounds, a password for trojan, and
one `sub_id` whose subscription URL returns all of them. That is why "add another
subscription" means "add another client", not "add another inbound".

Read `references/api.md` for the full endpoint list and request shapes. The rest of
this file is the workflow and the traps.

## Do it through the API, not with SQL

Writing straight into `inbounds.settings` looks tempting and is how older 3x-ui
guides do it, but in 3.8.5 that leaves `clients`, `client_inbounds` and
`client_traffics` out of sync, so the panel UI and traffic accounting disagree with
what xray actually enforces. `scripts/xui-client.sh` wraps the API calls.

```bash
ssh root@IP 'bash -s' -- add nail-2 --inbounds 1,2,4 --flow vision < scripts/xui-client.sh
ssh root@IP 'bash -s' -- list                                      < scripts/xui-client.sh
ssh root@IP 'bash -s' -- del nail-2                                < scripts/xui-client.sh
```

The script discovers the panel port, base path and subscription base from the
database, and defaults to every **enabled** inbound rather than a hardcoded list —
ids are not stable across installs and the XHTTP inbound ships disabled.

Credentials come from `$XUI_USER`/`$XUI_PASS`, then `/etc/x-ui/.admin`
("user:pass", mode 600), then `/root/x-ui-install.log`. The provisioning skill tells
operators to delete that log, so anything scripted should not depend on it. Note
that ssh does not forward environment variables — the assignment has to live inside
the remote command string:

```bash
ssh root@IP "XUI_USER=u XUI_PASS=p bash -s" -- add name < scripts/xui-client.sh
```

**`add` and `del` restart xray, which drops every live connection for every user.**
Pass `--no-restart` to batch changes, and use `xui-bulk.sh` when creating many
clients — it restarts once at the end instead of once per client.

## Four traps that cost real debugging time

**The panel generates the UUID and ignores yours.** You may pass `uuid` in the
request; it is accepted and discarded. `subId` and the trojan `password` *are*
honoured. Always read the UUID back after creating a client — from the database or,
better, from the subscription itself. Testing with the UUID you *sent* produces a
connection that authenticates as nobody: REALITY silently forwards it to the cover
site and you get an opaque TLS error, while trojan on the same server works fine
because its password did stick.

**Nothing reaches xray until `x-ui restart`.** The API writes the database and
returns `"success":true`, but the running xray config still has the old client list.
Symptom: a brand-new client fails on every protocol while existing ones work. Check
what xray actually loaded:

```bash
jq -r '.inbounds[] | select(.settings.clients|length>0)
       | "\(.tag) \([.settings.clients[].email]|join(","))"' /usr/local/x-ui/bin/config.json
```

The panel UI restarts xray for you; the API does not.

**`add` and `update` take different body shapes.** `add` wants the client wrapped
alongside the inbound list, `update` wants it flat. Sending the wrong one returns
`"client email is required"` even though the email is plainly there — the field is
simply not where the handler looks.

```
POST /panel/api/clients/add          {"client": {...}, "inboundIds": [1,2,4]}
POST /panel/api/clients/update/{email}   {...}          # flat, no wrapper
```

`tgId` is an int64, so `""` fails with an unmarshal error. Use `0`.

**nginx rewrites API errors to 404.** The panel vhost sets
`error_page 400 401 402 403 ... =404` with `proxy_intercept_errors on`, so a CSRF
rejection or an auth failure arrives as a bare 404 and sends you hunting for a wrong
URL. When debugging, talk to the panel directly and bypass nginx:

```bash
curl -sk https://127.0.0.1:<panel_port>/<base_path>/...
```

## Authentication

The panel issues a CSRF token as a `<meta name="csrf-token">` tag and requires it on
every POST as `X-CSRF-Token`. The session itself is the `3x-ui` cookie.

```bash
TOK=$(curl -sk -c jar "$B/" | grep -oE 'name="csrf-token" content="[^"]+"' | sed 's/.*content="//;s/"//')
curl -sk -b jar -c jar -X POST "$B/login" -H "X-CSRF-Token: $TOK" -d "username=$U&password=$P"
```

Reads are `GET`, writes are `POST`. Sending POST to a read endpoint returns 404,
which is easy to misread as "the route does not exist".

## Flow: set it on the client, let the panel place it

For VLESS+REALITY over TCP, `xtls-rprx-vision` is the right default. Set it once on
the client and the panel writes it only into the REALITY inbound, leaving WebSocket
and trojan with an empty flow — which is what those transports need, since vision is
invalid there and xray would reject the config. Verify after restart:

```bash
jq -r '.inbounds[] | select(.settings.clients|length>0)
       | "\(.tag) flows=\([.settings.clients[].flow // "-"]|join(","))"' /usr/local/x-ui/bin/config.json
```

## Verify before handing the link over

A subscription that parses is not a subscription that works. `scripts/verify-tunnels.sh`
builds a throwaway xray client for each protocol straight from the subscription
links, routes a real request through it, and reports the exit IP:

```bash
ssh root@IP 'bash -s' -- <sub_id> < scripts/verify-tunnels.sh
```

Driving the test from the subscription rather than from values you typed is what
catches the server-generated-UUID trap — the test uses exactly what the user's client
will use.

When writing your own probe, note two things that will mislead you:

- xray's default routing blocks `geoip:private`, so a tunnel test aimed at
  `127.0.0.1` is blackholed instantly and looks like a broken tunnel.
- sshd closes unauthenticated sessions after `LoginGraceTime` (120s by default), so
  holding an idle connection to port 22 measures sshd, not the tunnel.

## Per-client IP limits

`limitIp` is worth setting (2–3) when keys go to individual people: with `0` there is
no way to tell a shared key from a busy one. In 3.8.5 this is enforced through the
Xray core's online-stats API — the startup log says "using connection-based onlines
and access-log-free IP limit" — so unlike older guidance it needs neither the access
log nor fail2ban. Verify on the box before relying on it:

```bash
journalctl -u x-ui --no-pager | grep -i "IP limit"
```

Naming clients after people rather than `key-1…key-15` makes the traffic table
readable; `client_traffics` is the only place you will see who is actually consuming.

## Subscription URLs

```
https://<panel-domain>/<sub_path>/<sub_id>
```

`sub_path` lives in the `settings` table under `subPath`. The same URL serves
different content by User-Agent: anything matching `clash|clashx|clashn|mihomo|stash|surfboard`
gets a generated `clash.yaml`, everything else gets the standard base64 link list.
`?provider=1` bypasses the sniffing — the generated Clash config uses it for its own
`proxy-provider` refresh, so the proxies are fetched separately rather than embedded.
To download the Clash config by hand, spoof the agent:

```bash
curl -fsSL -A clash "https://<panel-domain>/<sub_path>/<sub_id>" -o clash.yaml
```
