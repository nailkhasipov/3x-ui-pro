#!/bin/bash
# Post-install verification. Run ON the server, as root:
#   ssh root@IP 'bash -s' -- panel.example.com cdn.example.com < scripts/verify-install.sh
PANEL="${1:?usage: verify-install.sh <panel-domain> <reality-domain>}"
REALITY="${2:?usage: verify-install.sh <panel-domain> <reality-domain>}"
fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
warn(){ printf '  \033[33mwarn\033[0m  %s\n' "$1"; }

echo "Services"
for s in x-ui nginx mtr-backend; do
  a=$(systemctl is-active "$s" 2>/dev/null); e=$(systemctl is-enabled "$s" 2>/dev/null)
  [ "$a" = active ] && [ "$e" = enabled ] && ok "$s active+enabled" || bad "$s active=$a enabled=$e"
done

echo "nginx config"
nginx -t >/dev/null 2>&1 && ok "nginx -t passes" || bad "nginx -t fails: $(nginx -t 2>&1 | tail -1)"

echo "Certificates"
for d in "$PANEL" "$REALITY"; do
  f="/etc/letsencrypt/live/$d/fullchain.pem"
  if [ -f "$f" ]; then
    days=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
    [ "$days" -gt 10 ] && ok "$d cert valid ${days}d" || bad "$d cert expires in ${days}d"
  else bad "$d has no certificate"; fi
done

echo "External reachability"
code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$PANEL/")
[ "$code" = 200 ] && ok "https://$PANEL/ -> 200 (cover site)" || bad "https://$PANEL/ -> $code"
code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "http://$PANEL/")
[ "$code" = 301 ] && ok "http -> https redirect" || warn "http://$PANEL/ -> $code (expected 301)"

echo "REALITY SNI routing"
subj=$(timeout 12 openssl s_client -connect "$PANEL:443" -servername "$REALITY" </dev/null 2>/dev/null | grep -m1 'subject=')
if grep -q "CN *= *$REALITY" <<<"$subj"; then ok "SNI $REALITY routes to the REALITY listener ($subj)"
else bad "SNI routing wrong, got: ${subj:-<no handshake>}"; fi

echo "Inbounds"
sqlite3 /etc/x-ui/x-ui.db \
  "SELECT '  inbound '||id||' '||remark||' proto='||protocol||' enabled='||enable||
   ' clients='||json_array_length(json_extract(settings,'\$.clients')) FROM inbounds;" 2>/dev/null
total=$(sqlite3 /etc/x-ui/x-ui.db "SELECT count(*) FROM clients;" 2>/dev/null)
[ "${total:-0}" -gt 0 ] && ok "$total client(s) defined" || warn "no clients yet - subscriptions will be empty"

echo "Known installer defects"
ws_alpn=$(sqlite3 /etc/x-ui/x-ui.db "SELECT alpn FROM hosts WHERE remark='ws';" 2>/dev/null)
[ "$ws_alpn" = '["http/1.1"]' ] && ok "ws host ALPN is http/1.1" \
  || bad "ws host ALPN is $ws_alpn - WebSocket will fail (h2 has no Upgrade header)"
grep -q proxy_timeout /etc/nginx/stream-enabled/stream.conf 2>/dev/null \
  && ok "stream proxy_timeout is set" \
  || warn "stream block has no proxy_timeout -> nginx default 10m idle applies to every :443 connection"
idle=$(jq -r '.policy.levels["0"].connIdle // empty' /usr/local/x-ui/bin/config.json 2>/dev/null)
if [ -n "$idle" ]; then ok "xray connIdle=${idle}s"
else warn "xray connIdle unset -> default 300s closes connections idle for 5 min (only affects IDLE ones)"; fi

echo "Firewall"
ufw status | grep -q "22/tcp.*ALLOW" && ok "ufw allows 22/tcp" || bad "ufw does NOT allow 22/tcp - you will be locked out"
for r in "80/tcp" "443/tcp" "443/udp"; do
  ufw status | grep -q "$r.*ALLOW" && ok "ufw allows $r" || bad "ufw missing $r"
done

echo "Kernel"
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] && ok "BBR enabled" || warn "BBR not active"

echo
if [ $fail -eq 0 ]; then
  echo "VERIFY PASSED  (server-side only)"
  echo
  echo "This says the box is configured correctly. It does NOT say users can reach it:"
  echo "every check above ran on the server itself, so an ISP-side block of this IP"
  echo "would still show all green. Before handing out keys, run"
  echo "  scripts/client-side-check.sh $(curl -s -m 5 ipv4.icanhazip.com | tr -d '[:space:]') <subscription-url>"
  echo "on the user's own machine, on their network, with other VPNs off."
else
  echo "VERIFY FAILED"
fi
exit $fail
