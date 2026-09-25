#!/bin/bash
# Preflight for x-ui-latest.sh. Run ON the target server, as root:
#   ssh root@IP 'bash -s' -- panel.example.com cdn.example.com < scripts/preflight.sh
# Exits non-zero if anything the installer hard-fails on is wrong.
PANEL="${1:?usage: preflight.sh <panel-domain> <reality-domain>}"
REALITY="${2:?usage: preflight.sh <panel-domain> <reality-domain>}"
fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }

echo "OS / CPU"
id=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
ver=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release)
case "$id:$ver" in
  ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ok "$id $ver is supported" ;;
  *) bad "$id $ver unsupported (need Ubuntu 24.04/26.04 or Debian 12/13)" ;;
esac
cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')
if grep -qi qemu <<<"$cpu"; then
  bad "QEMU-emulated CPU ($cpu) - ask the host for host-passthrough"
else ok "CPU: $cpu"; fi

echo "Domains"
if [ "$PANEL" = "$REALITY" ]; then bad "panel and REALITY domain are identical"; else ok "domains differ"; fi
myip=$(curl -s -m 8 ipv4.icanhazip.com | tr -d '[:space:]')
ok "server public IP: $myip"
for d in "$PANEL" "$REALITY"; do
  a=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
  if   [ -z "$a" ];        then bad "$d does not resolve"
  elif [ "$a" != "$myip" ]; then
    case "$a" in
      104.*|172.6[4-9].*|172.7[0-1].*|188.114.*|162.159.*)
        bad "$d -> $a looks like a Cloudflare proxy IP; turn the orange cloud off" ;;
      *) bad "$d -> $a but this server is $myip" ;;
    esac
  else ok "$d -> $a"; fi
done

echo "Ports"
for p in 80 443; do
  if ss -lnt "( sport = :$p )" | grep -q LISTEN; then
    bad "port $p already in use by: $(ss -lntp "( sport = :$p )" | awk 'NR==2{print $NF}')"
  else ok "port $p free"; fi
done

echo "Resources"
mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
swap=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
[ "$mem" -ge 900 ] && ok "RAM ${mem}MB" || warn "RAM ${mem}MB is tight"
[ "$swap" -gt 0 ] && ok "swap ${swap}MB" || warn "no swap - xray is the first thing the OOM killer takes"
free_disk=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$free_disk" -ge 3 ] && ok "disk ${free_disk}GB free" || bad "only ${free_disk}GB free on /"

echo "Existing install"
[ -d /etc/x-ui ] && warn "/etc/x-ui exists - the installer will wipe the previous install" || ok "no previous install"

echo
[ $fail -eq 0 ] && echo "PREFLIGHT PASSED" || echo "PREFLIGHT FAILED - fix the items above before installing"
exit $fail
