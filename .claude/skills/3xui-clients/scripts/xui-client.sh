#!/bin/bash
# 3x-ui 3.8.5 single-client management. Run ON the panel server, as root:
#   ssh root@IP 'bash -s' -- add <name> [--inbounds 1,2,4] [--flow vision] [--no-restart] < xui-client.sh
#   ssh root@IP 'bash -s' -- list                                                         < xui-client.sh
#   ssh root@IP 'bash -s' -- del <name> [--no-restart]                                    < xui-client.sh
#
# Credentials: $XUI_USER/$XUI_PASS, else /etc/x-ui/.admin ("user:pass", mode 600),
# else /root/x-ui-install.log. Over ssh the assignment goes INSIDE the command string:
#   ssh root@IP "XUI_USER=u XUI_PASS=p bash -s" -- add name < xui-client.sh
#
# NOTE: add/del restart xray, which drops every live connection for every user.
# Use --no-restart to batch changes, or xui-bulk.sh for many clients at once.
set -uo pipefail
DB=/etc/x-ui/x-ui.db
q() { sqlite3 "$DB" "$1"; }

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

PORT=$(q "SELECT value FROM settings WHERE key='webPort';")
BASE=$(q "SELECT value FROM settings WHERE key='webBasePath';" | sed 's#^/##;s#/$##')
B="https://127.0.0.1:${PORT}/${BASE}"
SUBBASE=$(q "SELECT value FROM settings WHERE key='subURI';" | sed 's#/$##')
[ -n "$SUBBASE" ] || SUBBASE="https://$(q "SELECT address FROM hosts ORDER BY inbound_id LIMIT 1;")/$(q "SELECT value FROM settings WHERE key='subPath';" | sed 's#^/##;s#/$##')"

JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
csrf() { curl -sk -b "$JAR" -c "$JAR" "$1" | grep -oE 'name="csrf-token" content="[^"]+"' | sed 's/.*content="//;s/"//'; }
TOK=$(csrf "$B/")
# urlencode: a password containing & + or % would otherwise corrupt the form body
curl -sk -b "$JAR" -c "$JAR" -X POST "$B/login" -H "X-CSRF-Token: $TOK" \
  --data-urlencode "username=$XUI_ADMIN" --data-urlencode "password=$XUI_SECRET" \
  | grep -q '"success":true' || { echo "login failed" >&2; exit 1; }
TOK=$(csrf "$B/panel/")
post() { curl -sk -b "$JAR" -c "$JAR" -X POST -H "X-CSRF-Token: $TOK" \
         -H "Content-Type: application/json" -d "$2" "$B$1"; }

restart_xray() {
  local p
  x-ui restart >/dev/null 2>&1
  p=$(q "SELECT port FROM inbounds WHERE enable=1 AND port>0 ORDER BY id LIMIT 1;")
  for i in $(seq 1 30); do nc -z 127.0.0.1 "${p:-8443}" 2>/dev/null && break; sleep 1; done
  sleep 2
}

show() {
  printf '%-14s %-38s %-18s %s\n' EMAIL UUID TROJAN-PASS SUBSCRIPTION
  while IFS='|' read -r e u p s; do
    printf '%-14s %-38s %-18s %s/%s\n' "$e" "$u" "$p" "$SUBBASE" "$s"
  done < <(q "SELECT email,uuid,password,sub_id FROM clients ORDER BY id;")
}

CMD="${1:-}"; shift || true
case "$CMD" in
  list) show ;;

  del)
    EMAIL="${1:?usage: del <name>}"; shift || true
    [[ "$EMAIL" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "name must match [A-Za-z0-9_-]+" >&2; exit 1; }
    NORESTART=no; [ "${1:-}" = "--no-restart" ] && NORESTART=yes
    post "/panel/api/clients/del/$EMAIL" ""; echo
    if [ $NORESTART = no ]; then restart_xray; echo "deleted $EMAIL, xray restarted (all sessions dropped)"
    else echo "deleted $EMAIL in the database; run 'x-ui restart' to apply"; fi ;;

  add)
    EMAIL="${1:?usage: add <name> [--inbounds ids] [--flow vision] [--no-restart]}"; shift || true
    [[ "$EMAIL" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "name must match [A-Za-z0-9_-]+" >&2; exit 1; }
    INBOUNDS=""; FLOW=""; NORESTART=no
    while [ $# -gt 0 ]; do
      case "$1" in
        --inbounds)   INBOUNDS="$2"; shift 2 ;;
        --flow)       [ "$2" = vision ] && FLOW="xtls-rprx-vision" || FLOW="$2"; shift 2 ;;
        --no-restart) NORESTART=yes; shift ;;
        *) shift ;;
      esac
    done
    # inbound ids are not stable across installs and the xhttp one ships disabled,
    # so default to whatever is actually enabled instead of hardcoding 1,2,4
    [ -n "$INBOUNDS" ] || INBOUNDS=$(q "SELECT group_concat(id) FROM (SELECT id FROM inbounds WHERE enable=1 ORDER BY id);")
    [ -n "$(q "SELECT 1 FROM clients WHERE email='$EMAIL';")" ] && { echo "$EMAIL already exists" >&2; exit 1; }

    pass=$(head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
    sub=$(head -c 4096 /dev/urandom  | tr -dc 'a-z0-9'     | head -c 16)
    ids=$(printf '[%s]' "$INBOUNDS")
    # add: client wrapped next to inboundIds; tgId is int64 - "" fails to unmarshal
    body=$(jq -cn --arg e "$EMAIL" --arg p "$pass" --arg s "$sub" --argjson ids "$ids" \
      '{client:{email:$e,password:$p,subId:$s,flow:"",limitIp:0,limitHwid:0,
                totalGB:0,expiryTime:0,enable:true,tgId:0,comment:"",reset:0},inboundIds:$ids}')
    r=$(post /panel/api/clients/add "$body")
    grep -q '"success":true' <<<"$r" || { echo "add failed: $r" >&2; exit 1; }
    # update takes a FLAT body - a wrapped one reports "client email is required"
    if [ -n "$FLOW" ]; then
      flat=$(jq -cn --arg e "$EMAIL" --arg p "$pass" --arg s "$sub" --arg f "$FLOW" \
        '{email:$e,password:$p,subId:$s,flow:$f,limitIp:0,limitHwid:0,
          totalGB:0,expiryTime:0,enable:true,tgId:0,comment:"",reset:0}')
      grep -q '"success":true' <<<"$(post "/panel/api/clients/update/$EMAIL" "$flat")" \
        || echo "warning: flow not applied" >&2
    fi

    if [ $NORESTART = no ]; then restart_xray
    else echo "NOTE: not restarted - xray still runs without this client until 'x-ui restart'"; fi

    echo "created (inbounds: $INBOUNDS):"
    # the panel generates the UUID itself and discards the one you send, so read it back
    q "SELECT '  email='||email||'  uuid='||uuid||'  trojan_pass='||password FROM clients WHERE email='$EMAIL';"
    echo "  subscription=$SUBBASE/$(q "SELECT sub_id FROM clients WHERE email='$EMAIL';")"
    if [ $NORESTART = no ]; then
      echo; echo "in xray:"
      jq -r '.inbounds[] | select(.settings.clients?|length>0)
             | "  \(.tag)  clients=\(.settings.clients|length)"' /usr/local/x-ui/bin/config.json
    fi ;;

  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
