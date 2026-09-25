#!/bin/bash
# End-to-end tunnel test driven by the subscription itself. Run ON the server:
#   ssh root@IP 'bash -s' -- <sub_id> < verify-tunnels.sh
# Builds a throwaway xray client per share link, routes a real request through it
# and reports the exit IP. Using the subscription as the source of truth is what
# catches the panel's server-generated UUID.
set -uo pipefail
SUBID="${1:?usage: verify-tunnels.sh <sub_id>}"
DB=/etc/x-ui/x-ui.db
XRAY=/usr/local/x-ui/bin/xray-linux-amd64
# subURI is what the panel itself hands out; the hosts table can legitimately
# carry several rows and its first one is not guaranteed to be the panel domain
URL="$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='subURI';" | sed 's#/$##')/$SUBID"
if [ "$URL" = "/$SUBID" ]; then
  DOMAIN=$(sqlite3 "$DB" "SELECT address FROM hosts ORDER BY inbound_id LIMIT 1;")
  SUBP=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='subPath';" | sed 's#^/##;s#/$##')
  URL="https://$DOMAIN/$SUBP/$SUBID"
fi

WORK=$(mktemp -d); trap 'pkill -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
curl -sk "$URL" | base64 -d > "$WORK/links.txt" 2>/dev/null
[ -s "$WORK/links.txt" ] || { echo "subscription $URL returned nothing" >&2; exit 1; }
echo "subscription: $URL"
echo

python3 - "$WORK" <<'PY'
import base64, json, os, sys, urllib.parse as up
work = sys.argv[1]
port = 10900
for line in open(f"{work}/links.txt"):
    line = line.strip()
    if not line: continue
    scheme, rest = line.split("://", 1)
    cred, rest = rest.split("@", 1)
    hostport, _, tail = rest.partition("?")
    query, _, tag = tail.partition("#")
    host, _, p = hostport.partition(":")
    q = {k: v[0] for k, v in up.parse_qs(query).items()}
    name = up.unquote(tag) or scheme
    net, sec = q.get("type", "tcp"), q.get("security", "none")
    alpn = q["alpn"].split(",") if q.get("alpn") else None

    stream = {"network": net, "security": "reality" if sec == "reality" else ("tls" if sec == "tls" else "none")}
    if sec == "reality":
        stream["realitySettings"] = {
            "serverName": q.get("sni", ""), "fingerprint": q.get("fp", "chrome"),
            "publicKey": q.get("pbk", ""), "shortId": q.get("sid", ""),
            "spiderX": up.unquote(q.get("spx", "/"))}
    elif sec == "tls":
        t = {"serverName": q.get("sni") or q.get("host") or host, "fingerprint": q.get("fp", "chrome")}
        if alpn: t["alpn"] = alpn
        stream["tlsSettings"] = t
    if net == "ws":
        stream["wsSettings"] = {"path": up.unquote(q.get("path", "/")), "host": q.get("host", host)}
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": up.unquote(q.get("serviceName", "")),
                                  "authority": q.get("authority", host)}
    elif net == "xhttp":
        x = {"path": up.unquote(q.get("path", "/")), "host": q.get("host", host)}
        if q.get("mode"): x["mode"] = q["mode"]
        stream["xhttpSettings"] = x

    if scheme == "vless":
        user = {"id": cred, "encryption": q.get("encryption", "none")}
        if q.get("flow"): user["flow"] = q["flow"]
        out = {"protocol": "vless", "settings": {"vnext": [{"address": host, "port": int(p), "users": [user]}]}}
    elif scheme == "trojan":
        out = {"protocol": "trojan",
               "settings": {"servers": [{"address": host, "port": int(p), "password": up.unquote(cred)}]}}
    else:
        continue
    out["streamSettings"] = stream
    cfg = {"log": {"loglevel": "warning"},
           "inbounds": [{"port": port, "listen": "127.0.0.1", "protocol": "socks",
                         "settings": {"udp": True}}],
           "outbounds": [out]}
    safe = "".join(c if c.isalnum() else "_" for c in name)[:24]
    json.dump(cfg, open(f"{work}/{port}_{safe}.json", "w"))
    port += 1
PY

pass=0; total=0
for cfg in "$WORK"/*.json; do
  [ -e "$cfg" ] || continue
  base=$(basename "$cfg" .json); p=${base%%_*}; label=${base#*_}
  total=$((total+1))
  "$XRAY" run -c "$cfg" > "$WORK/$p.log" 2>&1 & pid=$!
  for i in $(seq 1 20); do nc -z 127.0.0.1 "$p" 2>/dev/null && break; sleep 0.3; done
  ip=$(curl -s -m 20 --socks5-hostname "127.0.0.1:$p" https://ipv4.icanhazip.com | tr -d '[:space:]')
  code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' --socks5-hostname "127.0.0.1:$p" \
         https://www.gstatic.com/generate_204)
  if [ -n "$ip" ] && [ "$code" = 204 ]; then
    printf '  \033[32mok\033[0m    %-24s exit-IP=%s\n' "$label" "$ip"; pass=$((pass+1))
  else
    err=$(grep -iE 'rejected|failed|error' "$WORK/$p.log" | grep -v deprecated | tail -1)
    printf '  \033[31mFAIL\033[0m  %-24s %s\n' "$label" "${err:-no response through tunnel}"
  fi
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
done

echo
echo "$pass/$total tunnels working"
[ "$pass" = "$total" ]
