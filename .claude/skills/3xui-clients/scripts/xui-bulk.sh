#!/bin/bash
# Bulk-create 3x-ui clients. Run ON the panel server, as root:
#   ssh root@IP 'bash -s' -- key- 15 [--inbounds 1,2,4] [--flow vision] < xui-bulk.sh
#
# Creates <prefix>1 .. <prefix>N. Every client is created and updated over the API
# with xray restarted exactly once at the end — restarting per client would drop
# every live connection N times over.
set -uo pipefail
PREFIX="${1:?usage: xui-bulk.sh <prefix> <count> [--inbounds 1,2,4] [--flow vision]}"
COUNT="${2:?usage: xui-bulk.sh <prefix> <count> [--inbounds 1,2,4] [--flow vision]}"
shift 2
INBOUNDS=""; FLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --inbounds) INBOUNDS="$2"; shift 2 ;;
    --flow) [ "$2" = vision ] && FLOW="xtls-rprx-vision" || FLOW="$2"; shift 2 ;;
    *) shift ;;
  esac
done

DB=/etc/x-ui/x-ui.db
q() { sqlite3 "$DB" "$1"; }
PORT=$(q "SELECT value FROM settings WHERE key='webPort';")
BASE=$(q "SELECT value FROM settings WHERE key='webBasePath';" | sed 's#^/##;s#/$##')
B="https://127.0.0.1:${PORT}/${BASE}"
# subURI is authoritative; the hosts table may hold several rows and its first
# one is not guaranteed to be the panel domain
SUBBASE=$(q "SELECT value FROM settings WHERE key='subURI';" | sed 's#/$##')
[ -n "$SUBBASE" ] || SUBBASE="https://$(q "SELECT address FROM hosts ORDER BY inbound_id LIMIT 1;")/$(q "SELECT value FROM settings WHERE key='subPath';" | sed 's#^/##;s#/$##')"
# credentials: env, then /etc/x-ui/.admin ("user:pass", 600), then the install log
XUI_ADMIN="${XUI_USER:-}"; XUI_SECRET="${XUI_PASS:-}"
if [ -z "$XUI_ADMIN" ] && [ -r /etc/x-ui/.admin ]; then
  XUI_ADMIN=$(cut -d: -f1 /etc/x-ui/.admin); XUI_SECRET=$(cut -d: -f2- /etc/x-ui/.admin)
fi
if [ -z "$XUI_ADMIN" ] && [ -r /root/x-ui-install.log ]; then
  XUI_ADMIN=$(grep -m1 '^Username:' /root/x-ui-install.log | awk '{print $2}')
  XUI_SECRET=$(grep -m1 '^Password:' /root/x-ui-install.log | awk '{print $2}')
fi
[ -n "$XUI_ADMIN" ] && [ -n "$XUI_SECRET" ] || {
  echo "No credentials. Export XUI_USER/XUI_PASS or create /etc/x-ui/.admin (mode 600)." >&2; exit 1; }

JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
csrf() { curl -sk -b "$JAR" -c "$JAR" "$1" | grep -oE 'name="csrf-token" content="[^"]+"' | sed 's/.*content="//;s/"//'; }
TOK=$(csrf "$B/")
curl -sk -b "$JAR" -c "$JAR" -X POST "$B/login" -H "X-CSRF-Token: $TOK" \
     --data-urlencode "username=$XUI_ADMIN" --data-urlencode "password=$XUI_SECRET" \
     | grep -q '"success":true' || { echo "login failed" >&2; exit 1; }
TOK=$(csrf "$B/panel/")
post() { curl -sk -b "$JAR" -c "$JAR" -X POST -H "X-CSRF-Token: $TOK" \
         -H "Content-Type: application/json" -d "$2" "$B$1"; }

# ids are not stable across installs and the xhttp inbound ships disabled,
# so default to whatever is enabled instead of hardcoding 1,2,4
[ -n "$INBOUNDS" ] || INBOUNDS=$(q "SELECT group_concat(id) FROM (SELECT id FROM inbounds WHERE enable=1 ORDER BY id);")
echo "inbounds: $INBOUNDS"
ids=$(printf '[%s]' "$INBOUNDS")
created=0; skipped=0; failed=0
for i in $(seq 1 "$COUNT"); do
  email="${PREFIX}${i}"
  [[ "$email" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "  skip   $email (name must match [A-Za-z0-9_-]+)"; skipped=$((skipped+1)); continue; }
  if [ -n "$(q "SELECT 1 FROM clients WHERE email='$email';")" ]; then
    echo "  skip   $email (already exists)"; skipped=$((skipped+1)); continue
  fi
  pass=$(head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
  sub=$(head -c 4096 /dev/urandom  | tr -dc 'a-z0-9'     | head -c 16)
  # add: client wrapped next to inboundIds; tgId is an int64, "" would fail to unmarshal
  body=$(jq -cn --arg e "$email" --arg p "$pass" --arg s "$sub" --argjson ids "$ids" \
    '{client:{email:$e,password:$p,subId:$s,flow:"",limitIp:0,limitHwid:0,
              totalGB:0,expiryTime:0,enable:true,tgId:0,comment:"",reset:0},inboundIds:$ids}')
  r=$(post /panel/api/clients/add "$body")
  if ! grep -q '"success":true' <<<"$r"; then
    echo "  FAIL   $email: $r"; failed=$((failed+1)); continue
  fi
  # update takes a FLAT body - a wrapped one reports "client email is required"
  if [ -n "$FLOW" ]; then
    flat=$(jq -cn --arg e "$email" --arg p "$pass" --arg s "$sub" --arg f "$FLOW" \
      '{email:$e,password:$p,subId:$s,flow:$f,limitIp:0,limitHwid:0,
        totalGB:0,expiryTime:0,enable:true,tgId:0,comment:"",reset:0}')
    grep -q '"success":true' <<<"$(post "/panel/api/clients/update/$email" "$flat")" \
      || echo "  warn   $email: flow not applied"
  fi
  created=$((created+1))
done

echo "created=$created skipped=$skipped failed=$failed"
# the API only writes the database; xray keeps the old client list until restarted
if [ $created -gt 0 ]; then
  x-ui restart >/dev/null 2>&1
  rport=$(q "SELECT port FROM inbounds WHERE enable=1 AND port>0 ORDER BY id LIMIT 1;")
  for i in $(seq 1 30); do nc -z 127.0.0.1 "${rport:-8443}" 2>/dev/null && break; sleep 1; done; sleep 2
fi

echo
# read UUIDs back: the panel generates them itself and discards whatever was sent
printf '%-10s %-38s %-18s %s\n' EMAIL UUID TROJAN-PASS SUBSCRIPTION
while IFS='|' read -r e u p s; do
  printf '%-10s %-38s %-18s %s/%s\n' "$e" "$u" "$p" "$SUBBASE" "$s"
done < <(q "SELECT email,uuid,password,sub_id FROM clients WHERE email LIKE '${PREFIX}%' ORDER BY CAST(replace(email,'${PREFIX}','') AS INTEGER);")
echo
echo "in xray: $(jq -r '[.inbounds[]|select(.settings.clients?|length>0)|"\(.tag)=\(.settings.clients|length)"]|join("  ")' /usr/local/x-ui/bin/config.json)"
