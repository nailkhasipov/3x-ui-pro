#!/bin/bash
# Acceptance check. Run on the USER'S machine, on the network they will really use,
# with every other VPN OFF. A server-side check cannot detect an ISP-side block;
# this one can. Portable across macOS and Linux.
#   bash client-side-check.sh <server-ip> [subscription-url]
IP="${1:?usage: client-side-check.sh <server-ip> [subscription-url]}"
SUB="${2:-}"
BASEDIR="${XRAY_DIR:-$HOME/.cache/xray-check}"

# ping and nc differ between macOS and Linux (-W is ms vs s; -G is macOS-only),
# so probe ports with bash's /dev/tcp, which behaves the same everywhere.
port_open() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
if ping -c1 -W1 127.0.0.1 >/dev/null 2>&1; then PING="ping -c 3 -W 1"; else PING="ping -c 3 -W 1000"; fi

direct=$(curl -s -m 10 ipv4.icanhazip.com | tr -d '[:space:]')
echo "direct egress IP: ${direct:-<none>}   time: $(date '+%H:%M:%S')"
[ -z "$direct" ] && { echo "no internet"; exit 1; }
if [ "$direct" = "$IP" ]; then
  echo "ABORT: your traffic already exits through $IP, so you are inside this very"
  echo "       tunnel. Disconnect the VPN and re-run - nothing below would mean anything."
  exit 2
fi
echo "  ^ if that is not this network's own public IP, a VPN is still on and every"
echo "    result below is meaningless. Disconnect it and re-run."
echo

host=""
[ -n "$SUB" ] && host=$(sed -E 's#https?://([^/]+)/.*#\1#' <<<"$SUB")
if [ -n "$host" ]; then
  echo "== DNS =="
  isp=$(dig +short A "$host" | tr '\n' ' ')
  pub=$(dig +short A "$host" @1.1.1.1 | tr '\n' ' ')
  printf '  via ISP resolver: %s\n  via 1.1.1.1:      %s\n' "${isp:-<none>}" "${pub:-<none>}"
  [ "$isp" != "$pub" ] && echo "  DIFFERENT -> DNS-level block by the ISP"
fi

echo "== reachability of $IP =="
printf '  ICMP:     '; $PING "$IP" >/dev/null 2>&1 && echo "reply" || echo "NO REPLY"
tcp443=no
for p in 443 80 22; do
  printf '  tcp/%-4s  ' $p
  if port_open "$IP" $p; then echo OPEN; [ $p = 443 ] && tcp443=yes; else echo BLOCKED; fi
done

echo "== TLS: your SNI vs a neutral one, same IP =="
if [ "$tcp443" = no ]; then
  echo "  skipped: tcp/443 is blocked, so nothing can be concluded about names."
  echo "  => the ADDRESS is blocked. No configuration change on the server can fix this."
else
  for sni in "${host:-$IP}" www.microsoft.com; do
    printf '  SNI %-26s ' "$sni"
    r=$(timeout 12 openssl s_client -connect "$IP:443" -servername "$sni" </dev/null 2>&1)
    grep -q "Verify return code: 0\|certificate verify failed" <<<"$r" && echo "handshake OK" || echo "FAILED"
  done
  echo "  (only yours fails => the NAME is blocked, the address is still good)"
fi

[ -z "$SUB" ] && { echo; echo "no subscription URL given, skipping the tunnel leg"; exit 0; }

echo "== tunnel =="
XRAY="$BASEDIR/xray"
if [ ! -x "$XRAY" ]; then
  mkdir -p "$BASEDIR"
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  A=macos-arm64-v8a ;; Darwin-*)      A=macos-64 ;;
    Linux-aarch64) A=linux-arm64-v8a ;; Linux-x86_64)  A=linux-64 ;;
    *) echo "  unsupported platform: $(uname -sm)"; exit 1 ;;
  esac
  base="https://github.com/XTLS/Xray-core/releases/latest/download"
  curl -fsSL -o "$BASEDIR/x.zip" "$base/Xray-$A.zip" || { echo "  download failed"; exit 1; }
  # releases ship a .dgst with checksums; refuse to run an unverified binary
  if curl -fsSL -o "$BASEDIR/x.dgst" "$base/Xray-$A.zip.dgst" 2>/dev/null && [ -s "$BASEDIR/x.dgst" ]; then
    want=$(grep -iA1 'sha256' "$BASEDIR/x.dgst" | grep -oE '[0-9a-f]{64}' | head -1)
    got=$(shasum -a 256 "$BASEDIR/x.zip" 2>/dev/null | cut -d' ' -f1)
    [ -z "$got" ] && got=$(sha256sum "$BASEDIR/x.zip" | cut -d' ' -f1)
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      echo "  CHECKSUM MISMATCH - refusing to run the downloaded xray"; rm -f "$BASEDIR/x.zip"; exit 1
    fi
    [ -n "$want" ] && echo "  xray sha256 verified"
  else
    echo "  warning: no .dgst published, running an unverified binary"
  fi
  unzip -oq "$BASEDIR/x.zip" -d "$BASEDIR" && chmod +x "$XRAY"
fi

W=$(mktemp -d); trap 'pkill -f "$W" 2>/dev/null; rm -rf "$W"' EXIT
curl -fsSL -m 20 "$SUB" 2>/dev/null | base64 -d > "$W/links.txt" 2>/dev/null
[ -s "$W/links.txt" ] || { echo "  subscription unreachable from here"; exit 1; }

python3 - "$W" <<'PY'
import json,sys,urllib.parse as up
w=sys.argv[1]; port=10970
for line in open(f"{w}/links.txt"):
    line=line.strip()
    if not line: continue
    try: scheme,rest=line.split("://",1); cred,rest=rest.split("@",1)
    except ValueError: continue
    hp,_,tail=rest.partition("?"); query,_,tag=tail.partition("#")
    host,_,p=hp.partition(":"); q={k:v[0] for k,v in up.parse_qs(query).items()}
    name=up.unquote(tag) or scheme; net=q.get("type","tcp"); sec=q.get("security","none")
    alpn=q["alpn"].split(",") if q.get("alpn") else None
    st={"network":net,"security":"reality" if sec=="reality" else ("tls" if sec=="tls" else "none")}
    if sec=="reality":
        st["realitySettings"]={"serverName":q.get("sni",""),"fingerprint":q.get("fp","chrome"),
            "publicKey":q.get("pbk",""),"shortId":q.get("sid",""),"spiderX":up.unquote(q.get("spx","/"))}
    elif sec=="tls":
        t={"serverName":q.get("sni") or q.get("host") or host,"fingerprint":q.get("fp","chrome")}
        if alpn: t["alpn"]=alpn
        st["tlsSettings"]=t
    if net=="ws":
        st["wsSettings"]={"path":up.unquote(q.get("path","/")),"host":q.get("host",host)}
    elif net=="grpc":
        st["grpcSettings"]={"serviceName":up.unquote(q.get("serviceName","")),"authority":q.get("authority",host)}
    elif net=="xhttp":
        x={"path":up.unquote(q.get("path","/")),"host":q.get("host",host)}
        if q.get("mode"): x["mode"]=q["mode"]
        st["xhttpSettings"]=x
    if scheme=="vless":
        u={"id":cred,"encryption":q.get("encryption","none")}
        if q.get("flow"): u["flow"]=q["flow"]
        out={"protocol":"vless","settings":{"vnext":[{"address":host,"port":int(p),"users":[u]}]}}
    elif scheme=="trojan":
        out={"protocol":"trojan","settings":{"servers":[{"address":host,"port":int(p),"password":up.unquote(cred)}]}}
    else: continue
    out["streamSettings"]=st
    json.dump({"log":{"loglevel":"warning"},
      "inbounds":[{"port":port,"listen":"127.0.0.1","protocol":"socks","settings":{"udp":True}}],
      "outbounds":[out]}, open(f"{w}/{port}_{''.join(c if c.isalnum() else '_' for c in name)[:20]}.json","w"))
    port+=1
PY

for cfg in "$W"/*.json; do
  [ -e "$cfg" ] || continue
  b=$(basename "$cfg" .json); p=${b%%_*}; label=${b#*_}
  "$XRAY" run -c "$cfg" > "$W/$p.log" 2>&1 & pid=$!
  for i in $(seq 1 20); do port_open 127.0.0.1 $p && break; sleep 0.3; done
  exit_ip=$(curl -s -m 25 --socks5-hostname "127.0.0.1:$p" https://ipv4.icanhazip.com | tr -d '[:space:]')
  if [ -n "$exit_ip" ]; then
    spd=$(curl -s -m 30 -o /dev/null -w '%{speed_download}' --socks5-hostname "127.0.0.1:$p" \
          https://speed.cloudflare.com/__down?bytes=10000000 2>/dev/null)
    mbps=$(awk -v s="${spd:-0}" 'BEGIN{printf "%.1f", s*8/1000000}')
    # an exit IP other than the server is normal only if the server egresses via
    # WARP or a second hop; otherwise it means the traffic bypassed the tunnel
    if [ "$exit_ip" = "$IP" ]; then note=""; else note="  <- not the server's own IP; expected unless it egresses via WARP"; fi
    printf '  OK    %-22s exit=%-16s %s Mbit/s%s\n' "$label" "$exit_ip" "$mbps" "$note"
  else
    printf '  FAIL  %-22s %s\n' "$label" "$(grep -iE 'rejected|failed|error' "$W/$p.log" | grep -v deprecated | tail -1 | head -c 70)"
  fi
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
done
