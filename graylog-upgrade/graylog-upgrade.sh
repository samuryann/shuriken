#!/usr/bin/env bash
# shuriken: graylog-upgrade.sh
# Interactive, one-minor-at-a-time upgrade of Graylog Open for any box (Ubuntu or Debian, apt, systemd).
# Run as root inside tmux: sudo bash graylog-upgrade.sh   (no arguments needed)
# It scans the box, shows the installed version and the newest versions in Graylog's public repo index,
# shows the path, offers a menu (preview, upgrade, change target, quit), then for each
# hop: checks MongoDB range, swaps the Graylog repo, resolves the newest X.Y.z from apt-cache madison,
# simulates, asks, upgrades graylog-server, verifies it, then graylog-datanode (if installed).
# CHANGES: the graylog-X.Y-repository package, graylog-server, graylog-datanode, and the hold on those.
# NEVER TOUCHES: MongoDB, OpenSearch/Elasticsearch, Sidecar, kernel, any other package, any config file by hand.
# Safety: re-holds and restarts the server on any exit (also SIGHUP), and gates on checkpoint and health.
# Never reads or prints secrets: only specific keys are grepped from server.conf.

set -uo pipefail

# ---- Hop table (data driven). "minor|min MongoDB|max MongoDB|flag". Patch versions are NOT hardcoded:
# the newest X.Y.z is resolved from apt-cache madison after each repo swap. 7.2 is inference for MongoDB
# bounds and is only reachable when chosen explicitly.
HOPS=("6.0|5.0.7|7.9999|" "6.1|5.0.7|7.9999|" "6.2|5.0.7|8.2.9999|" "6.3|5.0.7|8.2.9999|"
      "7.0|7.0|8.2.9999|" "7.1|7.0|8.2.9999|" "7.2|7.0|8.2.9999|newer")
REPO_BASE=https://downloads.graylog.org/repo/debian/dists/stable   # <minor>/binary-amd64/Packages (public, read-only)

PKGS=(graylog-server)   # graylog-datanode is added in Main when installed
HAS_DN=0; HELD_START=""; MONGO_VER=""; ONLINE=0; DISC=(); ALL=(); PLAN=(); TARGET=""; RECOMMENDED=""
declare -A LATEST=()
PRE7=(); PRE_ALL=(); MISSING=(); PREV_REPO=""; REPO_PENDING=""
STARTED_REAL=0; HOPS_DONE=0; START_SVER=""; START_DVER=""; PREVIEW_ONLY=0
CONF=/etc/graylog/server/server.conf
SLOG=/var/log/graylog-server/server.log
DLOG=/var/log/graylog-datanode/datanode.log
LISTFILE=/etc/apt/sources.list.d/graylog.list
DATE=$(date +%Y%m%d)
LOG=/var/log/shuriken-graylog-upgrade-$DATE.log
BK=/root/graylog-backup-$DATE
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

DRY=0; TO=""; UNHELD=0; SERVER_STOPPED=0
HOP_START=0; HEALTH_URL=""; CURL_K=()
SNAP=""; SLOG_MARK=0:0; HOP_SLOG_MARK=0:0; HOP_DLOG_MARK=0:0
SRV_START_SECS=0; FALLBACK_WARNED=0; RESOLVED=""
# needrestart (Ubuntu 24.04) must never restart services behind our back.
APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l)
EPH_LO=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null); EPH_LO=${EPH_LO:-32768}

usage() {
  cat <<'EOF'
Usage: sudo bash graylog-upgrade.sh
No arguments are needed: it scans, shows the path, and offers a menu.
Optional extras:
  --dry-run   Preview only, no menu, change nothing.
  --to X.Y    Preselect the target minor, for example --to 7.0.
  --help      Show this help.
Upgrades graylog-server (and graylog-datanode when installed) one minor at a time, with a
simulation, a prompt and a verification pause for every hop.
Terms: the first run of each version asks you to type "accept". It is remembered in
  /root/.config/shuriken-graylog-upgrade/accepted
With no terminal on stdin and stdout, set SHURIKEN_ACCEPT_TERMS=1 to accept the terms.
On a terminal of at least 80x30 a header and status bar stay pinned at the top.
EOF
}

while (( $# )); do
  case $1 in
    --dry-run) DRY=1; PREVIEW_ONLY=1 ;;
    --to) shift; TO=${1:-}; [[ $TO =~ ^[0-9]+\.[0-9]+$ ]] || { echo "--to needs X.Y" >&2; exit 2; } ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

(( EUID == 0 )) || { echo "Run as root: sudo $0" >&2; exit 1; }
: </dev/tty 2>/dev/null || { echo "A terminal (/dev/tty) is required for prompts." >&2; exit 1; }

# ---- Colour: only on a real terminal (NO_COLOR or TERM=dumb switch it off). The log copy is always plain text.
VERSION="2026.11"
BRAND=shuriken
LICENSE_REF="the LICENSE file at https://github.com/samuryann/shuriken"
OUT_TTY=0; [[ -t 1 ]] && OUT_TTY=1   # real terminal on stdout, noted before the log tee replaces it
C_RST=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
  if command -v tput >/dev/null 2>&1 && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    C_RST=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim 2>/dev/null) || C_DIM=$'\033[2m'
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_CYN=$(tput setaf 6)
  else
    C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
  fi
fi
ESC=$'\033'
plain() { sed -u -E -e "s/${ESC}\\[[0-9;]*[A-Za-z]//g" -e "s/${ESC}\\([A-Z0-9]//g"; }   # strip colour codes for the log

( umask 077; touch "$LOG" ) && chmod 600 "$LOG"
exec > >(tee >(plain >>"$LOG")) 2>&1

f_ok()   { printf '%s[ OK ]%s %s' "$C_GRN" "$C_RST" "$*"; }
f_warn() { printf '%s[WARN]%s %s' "$C_YEL" "$C_RST" "$*"; }
f_stop() { printf '%s[STOP]%s %s' "$C_RED" "$C_RST" "$*"; }
f_info() { printf '%s[INFO]%s %s' "$C_CYN" "$C_RST" "$*"; }
f_hdr()  { # coloured title and a rule of = out to 78 columns
  local t="=== $* " n; n=$((78 - ${#t})); (( n < 3 )) && n=3
  printf '%s%s%s%s' "$C_BOLD$C_CYN" "$t" "$(printf '%*s' "$n" '' | tr ' ' '=')" "$C_RST"
}

say()  { printf '%s\n' "$*"; }
ok()   { say "$(f_ok "$*")"; }
info() { say "$(f_info "$*")"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
warn() { printf '%s\n' "$(f_warn "$*")"; }
die()  { printf '%s\n' "$(f_stop "$*")"; exit 1; }
hdr()  { printf '\n%s\n' "$(f_hdr "$*")"; }
banner() {
  local l
  while IFS= read -r l; do printf '%s%s%s\n' "$C_GRN" "$l" "$C_RST"; done <<'EOF'
  ___  ___    _   __   __ _      ___    ___
 / __|| _ \  /_\  \ \ / /| |    / _ \  / __|
| (_ ||   / / _ \  \ V / | |__ | (_) || (_ |
 \___||_|_\/_/ \_\  |_|  |____| \___/  \___|
 _   _  ___   ___  ___    _    ___   ___
| | | || _ \ / __|| _ \  /_\  |   \ | __|
| |_| ||  _/| (_ ||   / / _ \ | |) || _|
 \___/ |_|   \___||_|_\/_/ \_\|___/ |___|
EOF
  printf '%sshuriken%s  |  Graylog upgrade tool  |  v%s\n' "$C_BOLD" "$C_RST" "$VERSION"
}

# ---- Acceptance gate: first thing after the banner. Remembered per VERSION; log gets one line, not the text.
TERMS_DIR=/root/.config/$BRAND-graylog-upgrade
TERMS_FILE=$TERMS_DIR/accepted
terms_gate() {
  local envv=${BRAND^^}_ACCEPT_TERMS ans line when
  if [[ -r $TERMS_FILE ]] && line=$(head -n 1 "$TERMS_FILE" 2>/dev/null) && [[ $line == "version=$VERSION "* ]]; then
    when=${line##*date=}
    say "Terms accepted on ${when%%T*}."
    printf 'TERMS: already accepted (version %s, %s)\n' "$VERSION" "$when" >>"$LOG"
    return 0
  fi
  say ""
  say "${C_BOLD}Terms of use${C_RST} (please read)"
  say "  - Free to use and modify under the MIT licence with the Commons Clause. Not for sale."
  say "  - Provided as is, with no warranty of any kind."
  say "  - You are responsible for what it does on your systems."
  say "  - Take a VM snapshot or a backup first."
  say "  - It changes packages (graylog-server, graylog-datanode and the Graylog repo)"
  say "    and it restarts services."
  say "  - Full licence text: $LICENSE_REF."
  say ""
  if (( ! OUT_TTY )) && [[ ! -t 0 ]]; then   # no terminal on stdin or stdout: explicit opt-in only
    if [[ ${!envv:-} == 1 ]]; then
      say "Terms accepted through $envv=1."
      printf 'TERMS: accepted via %s=1 (version %s)\n' "$envv" "$VERSION" >>"$LOG"
      return 0
    fi
    say "No terminal. Set $envv=1 to accept the terms and run non-interactively."
    exit 1
  fi
  printf '%sType "accept" to continue (anything else exits):%s ' "$C_BOLD" "$C_RST"
  read -r ans </dev/tty || die "No terminal input."
  ans=${ans,,}; ans=${ans//[[:space:]]/}
  if [[ $ans != accept ]]; then
    printf 'TERMS: not accepted (version %s)\n' "$VERSION" >>"$LOG"
    say "Not accepted. Nothing was changed."; exit 0
  fi
  printf 'TERMS: accepted (version %s)\n' "$VERSION" >>"$LOG"
  if ! ( umask 077; mkdir -p "$TERMS_DIR" && printf 'version=%s date=%s\n' "$VERSION" "$(date -u +%FT%TZ)" >"$TERMS_FILE" ) 2>/dev/null; then
    warn "Could not save the acceptance in $TERMS_DIR. You will be asked again next run."
  fi
}

# ---- Pinned header: scroll region below a banner or title plus a status bar. Display only.
# Needs a tty on stdout, TERM not dumb, 80x30 or larger. All writes go to /dev/tty, never through the log tee.
# Redraws happen only at fixed points (set_phase, status_refresh), never in the background and never at a prompt.
PIN=0; PIN_ROWS=0; PIN_COLS=0; HDR_H=0; PHASE=Terms
pin_w() { { printf '%s' "$1" >/dev/tty; } 2>/dev/null || true; }
pin_size() { # sets PIN_ROWS and PIN_COLS; fails when the terminal is too small
  local sz
  sz=$(stty size </dev/tty 2>/dev/null) || return 1
  PIN_ROWS=${sz% *}; PIN_COLS=${sz#* }
  [[ $PIN_ROWS =~ ^[0-9]+$ && $PIN_COLS =~ ^[0-9]+$ ]] || return 1
  (( PIN_ROWS >= 30 && PIN_COLS >= 80 ))
}
pin_head() { # escape string that draws the title rows and the rule (status rows are drawn by status_refresh)
  local buf="" r=1 l
  if (( HDR_H == 12 )); then
    while IFS= read -r l; do buf+="${ESC}[${r};1H${ESC}[2K$l"; r=$((r + 1)); done < <(banner)
  else
    buf+="${ESC}[1;1H${ESC}[2K${C_BOLD}${BRAND}${C_RST}  |  Graylog upgrade  |  v${VERSION}"
    buf+="${ESC}[2;1H${ESC}[2K${C_DIM}Log: ${LOG}${C_RST}"
  fi
  buf+="${ESC}[$((HDR_H - 2));1H${ESC}[2K${ESC}[$((HDR_H - 1));1H${ESC}[2K"
  buf+="${ESC}[${HDR_H};1H${ESC}[2K${C_DIM}$(printf '%*s' "$PIN_COLS" '' | tr ' ' '-')${C_RST}"
  printf '%s' "$buf"
}
pin_apply() { # set the scroll region below the header, draw the header, keep the cursor where it was
  HDR_H=5; (( PIN_ROWS >= 45 )) && HDR_H=12
  pin_w "${ESC}7${ESC}[?7l${ESC}[$((HDR_H + 1));${PIN_ROWS}r$(pin_head)${ESC}[?7h${ESC}8"
  status_refresh
}
pin_init() { # returns 1 (nothing done) when the header cannot be pinned
  (( OUT_TTY )) && [[ ${TERM:-dumb} != dumb ]] && pin_size || return 1
  PIN=1
  pin_w "${ESC}[2J${ESC}[H"
  pin_apply
  pin_w "${ESC}[$((HDR_H + 1));1H"
  return 0
}
pin_svc() { # label unit
  if systemctl is-active --quiet "$2" 2>/dev/null; then printf '%s %sOK%s' "$1" "$C_GRN" "$C_RST"
  else printf '%s %sDOWN%s' "$1" "$C_RED" "$C_RST"; fi
}
status_refresh() { # redraw the two status rows without moving the cursor
  (( PIN )) || return 0
  local host sv dv hl hold s1 s2 dsvc
  host=$(hostname -s 2>/dev/null) || host=host; host=${host:0:14}
  if [[ $PHASE == Terms ]]; then
    s1="Host $host  |  v$VERSION"; s2="Phase: Terms (acceptance required)"
  else
    sv=$(pkgver graylog-server); sv=${sv#*:}; sv=${sv%%-*}
    dv=$(pkgver graylog-datanode); dv=${dv#*:}; dv=${dv%%-*}
    if [[ -z $HEALTH_URL ]]; then hl="${C_DIM}n/a${C_RST}"
    elif curl -s --max-time 2 "${CURL_K[@]}" "$HEALTH_URL" 2>/dev/null | grep -q ALIVE; then hl="${C_GRN}ALIVE${C_RST}"
    else hl="${C_RED}DEAD${C_RST}"; fi
    if apt-mark showhold 2>/dev/null | grep -qx graylog-server; then hold=held; else hold="${C_YEL}NOT held${C_RST}"; fi
    if [[ -n $dv ]]; then dsvc=$(pin_svc datanode graylog-datanode); else dsvc="datanode ${C_DIM}n/a${C_RST}"; fi
    s1="Host $host | Server ${sv:--} | Datanode ${dv:--} | Health $hl"
    s2="$(pin_svc mongod mongod) | $(pin_svc server graylog-server) | $dsvc | Phase: $PHASE | Hold: $hold"
  fi
  pin_w "${ESC}7${ESC}[?7l${ESC}[$((HDR_H - 2));1H${ESC}[2K $s1${C_RST}${ESC}[$((HDR_H - 1));1H${ESC}[2K $s2${C_RST}${ESC}[?7h${ESC}8"
  return 0
}
set_phase() { PHASE=$1; status_refresh; }
pin_winch() { # SIGWINCH: recompute the size, reset the region, redraw
  (( PIN )) || return 0
  if pin_size; then pin_apply; else PIN=0; pin_w "${ESC}[r${ESC}[?7h"; fi
}
pin_restore() { # full scroll region back, cursor to the bottom, cursor visible. Safe to call twice.
  (( PIN )) || return 0
  trap '' WINCH; PIN=0
  pin_w "${ESC}[r${ESC}[?7h${ESC}[999;1H${ESC}[?25h"
}

# Run a command, or only print it in dry-run mode.
run() {
  if (( DRY )); then dim "[dry-run] $*"; return 0; fi
  say "+ $*"
  "$@"
}
must() { run "$@" || die "Command failed: $*"; }

# ask "question" Y|N "recommendation text"  -> returns 0 for yes, 1 for no. Reads /dev/tty.
ask() {
  local q=$1 def=$2 rec=${3:-} hint ans rc
  if (( DRY )); then dim "[preview] $q -> yes (automatic)"; return 0; fi
  if [[ $def == Y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  [[ -n $rec ]] && hint+=" ($rec)"
  while true; do
    printf '%s%s%s %s ' "$C_BOLD" "$q" "$C_RST" "$hint"
    read -r ans </dev/tty || die "No terminal input."
    ans=${ans:-$def}
    case ${ans,,} in y|yes) rc=0 ;; n|no) rc=1 ;; *) continue ;; esac
    printf 'PROMPT: %s %s -> %s\n' "$q" "$hint" "$ans" >>"$LOG"
    return $rc
  done
}

pkgver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }

restore_holds() { # hold the Graylog packages again; say so if one was not held when we started
  local p
  for p in "${PKGS[@]}"; do
    [[ $HELD_START == *" $p "* ]] || say "$p was NOT held at start. Holding it anyway."
  done
  apt-mark hold "${PKGS[@]}"
}
rehold() { # output goes straight to the log: the tee pipe may already be dead (SIGHUP)
  if (( UNHELD )) && (( ! DRY )); then
    say "Restoring holds on ${PKGS[*]}"
    restore_holds >>"$LOG" 2>&1 || warn "Could not re-hold. Run: apt-mark hold ${PKGS[*]}"
  fi
  UNHELD=0
}
# out: write to the log file and the terminal directly, never through tee, never fatal.
out() { { printf '%s\n' "$*" | plain >>"$LOG"; } 2>/dev/null || true; printf '%s\n' "$*" 2>/dev/null >/dev/tty || true; }
on_exit() {
  local rc=$?
  trap '' PIPE HUP INT TERM
  say() { out "$@"; }; warn() { out "$(f_warn "$*")"; }; hdr() { out ""; out "$(f_hdr "$*")"; }
  rehold   # FIRST: the holds matter more than any message
  pin_restore   # then give the terminal its full scroll region back, before any message
  if (( SERVER_STOPPED )) && [[ $(systemctl is-active graylog-server 2>/dev/null) != active ]]; then
    say "graylog-server was stopped by this tool and is not running. Trying to start it (installed: $(pkgver graylog-server))."
    timeout 120 systemctl start graylog-server >>"$LOG" 2>&1 || true
    if [[ $(systemctl is-active graylog-server 2>/dev/null) == active ]]; then ok "graylog-server started again."
    else warn "graylog-server did NOT start. Check: systemctl status graylog-server ; journalctl -u graylog-server -n 50 ; dpkg --audit"; fi
  fi
  if (( rc != 0 )); then
    if [[ -n $REPO_PENDING ]]; then
      say "The Graylog apt repo is now on the new minor but no package was upgraded. To put it back:"
      say "  wget -O /tmp/r.deb https://packages.graylog2.org/repo/packages/graylog-$REPO_PENDING-repository_latest.deb && chmod 644 /tmp/r.deb && apt-get install -y -o Dpkg::Options::=--force-confnew /tmp/r.deb && apt-get update"
    fi
    say "If apt was interrupted, check: dpkg --audit ; apt-mark showhold ; dpkg -l 'graylog*'"
    say "Do not run apt upgrade. Re-run this tool to continue: it resumes from the installed versions."
  fi
  [[ -n $SNAP ]] && rm -f "$SNAP"
  print_summary "$rc"
  say "Exit code $rc. Log: $LOG"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap pin_winch WINCH
trap '' PIPE   # a dead tee must not kill us before on_exit has re-held the packages

print_summary() { # exit code; only after a real (non-preview) walkthrough started
  (( STARTED_REAL )) || return 0
  hdr "Summary"
  say "Start: graylog-server $START_SVER${START_DVER:+, graylog-datanode $START_DVER}"
  say "Now:   graylog-server $(pkgver graylog-server)$( (( HAS_DN )) && echo ", graylog-datanode $(pkgver graylog-datanode)")"
  say "Hops completed: $HOPS_DONE of ${#PLAN[@]} (target $TARGET)$( (( $1 != 0 )) && echo ". Stopped early: see messages above")"
  say "Holds now: $(apt-mark showhold | tr '\n' ' ')"
  say "Log: $LOG"
  say "Reminders:"
  say "  - Run the UI checklist on the final version (Nodes, Inputs, Search, Sidecars$( (( HAS_DN )) && echo ', Data Nodes'))."
  dpkg --compare-versions "$TARGET" ge 7.1 && say "  - 7.1 or later: fix notification templates (aggregation_conditions, custom Teams) and test them."
  say "  - Remove the VM checkpoint after a few days of stable running."
  [[ -d $BK ]] && say "  - $BK holds password_secret. Keep it on the server only."
}

# ---- Health and wait helpers
load_health_url() {
  local bind tls host port scheme=http
  bind=$(grep -E '^[[:space:]]*http_bind_address[[:space:]]*=' "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '[:space:]')
  tls=$(grep -E '^[[:space:]]*http_enable_tls[[:space:]]*=' "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '[:space:]')
  bind=${bind:-127.0.0.1:9000}
  if [[ $bind == *:* ]]; then host=${bind%:*}; port=${bind##*:}; else host=$bind; port=9000; fi
  case $host in 0.0.0.0|::|'[::]'|'') host=127.0.0.1 ;; esac
  if [[ ${tls,,} == true ]]; then scheme=https; CURL_K=(-k); fi
  HEALTH_URL="$scheme://$host:$port/api/system/lbstatus"
}
alive() { curl -s --max-time 5 "${CURL_K[@]}" "$HEALTH_URL" 2>/dev/null | grep -q ALIVE; }

# Byte-offset marks ("inode:size") so we only ever look at lines written after a point in time.
log_mark() { stat -c '%i:%s' "$1" 2>/dev/null || echo 0:0; }
new_lines() { # file mark -> lines added since the mark (whole file if it was rotated)
  local f=$1 m=$2 cur size=${2##*:}
  cur=$(stat -c '%i:%s' "$f" 2>/dev/null) || return 0
  if [[ ${cur%%:*} != "${m%%:*}" ]] || (( ${cur##*:} < size )); then size=0; fi
  tail -c +$((size + 1)) "$f" 2>/dev/null
}
# No timestamp parsing: look only at server.log lines added after the mark taken before the start.
up_and_running() { local n; n=$(new_lines "$SLOG" "$SLOG_MARK" | grep -c 'Graylog server up and running'); (( n > 0 )); }
# The old server process is stopped before the mark, so ALIVE can only come from the new one.
# If the log line never shows (format change), accept ALIVE after 180 s with a warning.
server_ready() {
  alive || return 1
  up_and_running && return 0
  if (( SECONDS - SRV_START_SECS >= 180 )); then
    (( FALLBACK_WARNED )) || { printf '\n'; warn "No 'up and running' line in new log output, but lbstatus is ALIVE. Accepting. Check server.log."; FALLBACK_WARNED=1; }
    return 0
  fi
  return 1
}

port_listening() { ss -H -lnt 2>/dev/null | awk -v p="$1" '{n=split($4,a,":"); if (a[n]==p) f=1} END{exit !f}'; }
datanode_ready() { local p; for p in 8999 9200 9300; do port_listening "$p" || return 1; done; }

wait_for() { # secs label cmd...
  local secs=$1 label=$2 end; shift 2
  end=$((SECONDS + secs))
  printf 'Waiting for %s (up to %ss) ' "$label" "$secs"
  while (( SECONDS < end )); do
    if "$@"; then printf ' %sok%s\n' "$C_GRN" "$C_RST"; return 0; fi
    printf '.'; sleep 5
  done
  printf ' %stimed out%s\n' "$C_RED" "$C_RST"; return 1
}

# wait_stage secs label logfile hook cmd...   (hook is a function name or "-")
wait_stage() {
  local secs=$1 label=$2 lf=$3 hook=$4; shift 4
  if (( DRY )); then dim "[dry-run] would wait for $label (up to ${secs}s)"; return 0; fi
  until wait_for "$secs" "$label" "$@"; do
    dim "--- last 40 lines of $lf ---"
    tail -n 40 "$lf" 2>/dev/null
    dim "--- end ---"
    [[ $hook != - ]] && "$hook"
    ask "Keep waiting for $label?" Y "recommended unless the log shows a clear failure" || die "Gave up waiting for $label."
  done
  status_refresh
}

preflight_hint() {
  dim "--- preflight and MongoDB version lines (7.0 hop) ---"
  new_lines "$SLOG" "$HOP_SLOG_MARK" | grep -iE 'preflight|mongodb version' | tail -n 10
  dim "--- end ---"
}

# ---- Snapshots and checks
# TCP and UDP listeners below the ephemeral range (ephemeral UDP sockets churn and would false-alarm).
listeners() { ss -H -lntu 2>/dev/null | awk -v lo="$EPH_LO" '{n=split($5,a,":"); p=a[n]; if (p ~ /^[0-9]+$/ && p+0 < lo) print $1" "p}' | sort -u; }

compare_listeners() {
  local after gone new t=0
  after=$(mktemp)
  while :; do  # inputs start after "up and running": allow up to 90 s to come back
    listeners >"$after"
    # Data Node ports 8999/9200/9300 are verified by datanode_ready, not here.
    gone=$(comm -23 "$SNAP" "$after"); (( ! HAS_DN )) || gone=$(grep -Ev ' (8999|9200|9300)$' <<<"$gone")
    [[ -z $gone ]] && break
    (( t >= 90 )) && break
    sleep 10; t=$((t + 10))
  done
  new=$(comm -13 "$SNAP" "$after")
  if [[ -n $gone ]]; then
    warn "Listeners present at tool start that are still GONE after ${t}s (proto port):"; say "$gone"
    say "Check System > Inputs and re-run: ss -H -lntu"
  else
    ok "Listeners: nothing missing compared with the snapshot at tool start (ports below $EPH_LO, excluding Data Node ports)."
  fi
  [[ -n $new ]] && { info "New listeners since tool start:"; say "$new"; }
  rm -f "$after"
}

post_hop_checks() { # minor target
  local minor=$1 tgt=$2 p v since
  hdr "Checks after the $minor hop"
  since=$(date -d "@$HOP_START" '+%Y-%m-%d %H:%M:%S')
  say "Journal errors since $since:"
  local ju=(); for p in "${PKGS[@]}"; do ju+=(-u "$p"); done
  journalctl "${ju[@]}" -p err --since "$since" --no-pager 2>&1 | tail -n 30
  compare_listeners
  for p in "${PKGS[@]}"; do
    v=$(pkgver "$p")
    say "$p version: ${v:-unknown} (server target $tgt) hold: $(apt-mark showhold | grep -qx "$p" && echo held || echo NOT HELD)"
  done
  say "Services (mongod ${PKGS[*]}): $(systemctl is-active mongod "${PKGS[@]}" 2>&1 | tr '\n' ' ')"
  say "Health: $(alive && echo "${C_GRN}ALIVE${C_RST}" || echo "${C_RED}NOT ALIVE${C_RST}")"
  say "ERROR/FATAL lines in server.log and datanode.log since hop start (last 10 each):"
  new_lines "$SLOG" "$HOP_SLOG_MARK" | grep -E ' (ERROR|FATAL) ' | tail -n 10
  (( HAS_DN )) && { new_lines "$DLOG" "$HOP_DLOG_MARK" | grep -E ' (ERROR|FATAL) ' | tail -n 10; }
  find /etc/graylog /etc/default -name '*.dpkg-*' 2>/dev/null | sed 's/^/New conffile (review later, do not swap now): /'
  say ""; say "${C_BOLD}UI checklist (log in as admin):${C_RST}"
  cat <<'EOF'
  [ ] System > Nodes: one node, green, new version
  [ ] System > Data Nodes (Data Node installs): available, same version as the server
  [ ] System > Inputs: every input Running
  [ ] Search, last 5 minutes: new messages arriving from your usual sources (syslog devices, Sidecars)
  [ ] System > Sidecars: same Sidecars active as before
  [ ] Alerts > Notifications: run Test notification on each
EOF
}

hop_warn() {
  case $1 in
    6.3) say "Notes: new input_types:create permission (auto-migrated). Report Creator role needed (Enterprise)." ;;
    7.0) say "Notes: Java 21 bundled. Needs MongoDB 7.0+ (8.0.38 is fine, never set skip_preflight_checks)."
         say "       Kafka inputs: brokers 2.0 and older no longer work."
         say "       REST API: urlwhitelist is renamed urlallowlist; create payloads are wrapped (entity / share_request)."
         say "       Data Lake migrations make first start slow (allow up to 10 minutes)."
         say "       API tokens: admin only creation, 30 day default expiry for new tokens. Existing tokens unaffected." ;;
    7.1) warn "7.1 logs EVERYONE out, including you. Log in again after the server starts."
         say "Notes: aggregation_conditions keys change from count\\(\\) to count, sum\\(field\\) to sum_field."
         say "       Teams Notification V2 loses the Time Zone field (custom templates need DATE()/TIME())."
         say "       AWS Kinesis/CloudWatch inputs need extra DynamoDB IAM permissions." ;;
    7.2) warn "7.2 is newer than the path this tool was reviewed against. Read the 7.2 upgrade notes first." ;;
    *)   say "Notes: no hop notes in this tool for $1. Read the Graylog UPGRADING notes for $1 first." ;;
  esac
}
hop_after() {
  [[ $1 == 7.1 ]] || return 0
  hdr "7.1 follow-up"
  say "Fix notification templates that use aggregation_conditions (count\\(\\) > count) and custom Teams templates."
  say "Use Test notification on each. Search the last 15 minutes and open a recent message to confirm timestamps and date fields."
  say "Wait 30 minutes, then re-check inputs, ERROR lines and Data Node availability."
}

# ---- Package steps
hop_row() { local h; for h in "${HOPS[@]}"; do [[ ${h%%|*} == "$1" ]] && { printf '%s' "$h"; return 0; }; done; return 1; }

resolve_version() { # pkg minor -> sets RESOLVED = newest X.Y.z-rev in the repo (no subshell, so die and warn work)
  local pkg=$1 minor=$2 v
  v=$(apt-cache madison "$pkg" 2>/dev/null | awk -F'|' -v m="$minor" '{gsub(/ /,"",$2); if (index($2,m".")==1 && $2 !~ /\.(alpha|beta|rc)\./) print $2}' | sort -V | tail -n 1)
  if [[ -z $v ]]; then
    if (( DRY )); then v=${LATEST[$minor]:-$minor.x}; dim "[preview] repo not switched, assuming $v for $pkg"
    else die "apt-cache madison shows no $minor.x for $pkg."; fi
  fi
  RESOLVED=$v
}

mongo_version() { # sets MONGO_VER to x.y[.z] or empty (read-only)
  local v
  v=$(dpkg-query -W -f='${Version}' mongodb-org-server 2>/dev/null)
  [[ -n $v ]] || v=$(mongod --version 2>/dev/null | awk '/db version/{sub(/^v/,"",$3); print $3; exit}')
  MONGO_VER=$(sed -E 's/^[0-9]+://; s/^v//; s/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' <<<"$v")
  [[ $MONGO_VER =~ ^[0-9]+\.[0-9]+ ]] || MONGO_VER=""
}
mongo_check() { # minor min max
  mongo_version
  if [[ -z $MONGO_VER ]]; then
    warn "Could not detect the MongoDB version (remote, container or tarball install?). Needed (built-in table): $2 to ${3%.9999}.x for Graylog $1."
    (( DRY )) && die "MongoDB version not detected. Preview stops here (it will not assume it is fine)."
    ask "Continue without a MongoDB check?" N "answer y only if you have verified it" || die "MongoDB version not verified."
    return 0
  fi
  if dpkg --compare-versions "$MONGO_VER" lt "$2" || dpkg --compare-versions "$MONGO_VER" gt "$3"; then
    die "MongoDB $MONGO_VER is outside the built-in table range $2 to ${3%.9999}.x for Graylog $1. Nothing was changed. Fix MongoDB separately (this tool never touches it)."
  fi
  ok "MongoDB $MONGO_VER is within $2 to ${3%.9999}.x for Graylog $1 (built-in table)."
}

simulate_install() { # pkg version: abort if anything but pkg would change
  local pkg=$1 ver=$2 out changes others
  if (( DRY )); then dim "[preview] apt simulation SKIPPED for $pkg=$ver (the repo is not switched in preview). A real run simulates it and aborts if any other package would change."; return 0; fi
  out=$(LC_ALL=C apt-get -s install "${APT_OPTS[@]}" "$pkg=$ver" 2>&1) || { say "$out"; die "Simulation failed for $pkg=$ver."; }
  changes=$(grep -E '^(Inst|Remv|Purg) ' <<<"$out")
  say "Simulated changes for $pkg=$ver:"; say "${changes:-  (none)}"
  grep -qE "^Inst $pkg( |:)" <<<"$changes" || die "Simulation does not show $pkg being installed at $ver."
  # Field 2 is the package name (strip :arch). Anything that is not "Inst <pkg>" is unexpected.
  others=$(awk -v p="$pkg" '{n=$2; sub(/:.*/,"",n); if (n != p || $1 != "Inst") print $1" "n}' <<<"$changes")
  [[ -z $others ]] || die "Simulation for $pkg=$ver would also change: $(paste -sd, - <<<"$others" | sed 's/,/, /g') (expected only: Inst $pkg). graylog-datanode is upgraded only AFTER the server is verified. Nothing was installed."
}

install_pkg() { # pkg version
  local pkg=$1 ver=$2 cur
  cur=$(pkgver "$pkg")
  if [[ $cur == "$ver" ]]; then say "$pkg already at $ver, skipping install."; return 0; fi
  simulate_install "$pkg" "$ver"
  ask "Upgrade $pkg to $ver?" Y recommended || die "Declined $pkg upgrade."
  must "${APT_ENV[@]}" apt-get install -y "${APT_OPTS[@]}" "$pkg=$ver"
}

simulate_repo_deb() { # deb: only graylog-X.Y-repository packages may change
  local out bad
  if (( DRY )); then dim "[preview] apt simulation SKIPPED for the repository package (nothing downloaded in preview)."; return 0; fi
  out=$(LC_ALL=C apt-get -s install -o Dpkg::Options::=--force-confnew "$1" 2>&1) || { say "$out"; die "Simulation failed for $1."; }
  bad=$(grep -E '^(Inst|Remv|Purg) ' <<<"$out" | awk '{n=$2; sub(/:.*/,"",n); if (n !~ /^graylog-[0-9]+\.[0-9]+-repository$/) print $1" "n}')
  [[ -z $bad ]] || die "Repository package install would also change: $(tr '\n' ',' <<<"$bad")"
}

swap_repo() { # minor
  local minor=$1 dir deb
  if (( DRY )); then dir=/tmp/DRYRUN; else dir=$(mktemp -d) || die "mktemp failed"; chmod 755 "$dir"; fi
  deb=$dir/graylog-$minor-repository_latest.deb
  must wget -q -O "$deb" "https://packages.graylog2.org/repo/packages/graylog-$minor-repository_latest.deb"
  (( DRY )) || chmod 644 "$deb"   # apt's _apt user must be able to read it
  simulate_repo_deb "$deb"
  PREV_REPO=$(dpkg -l 2>/dev/null | awk '/^ii +graylog-[0-9.]+-repository/{n=$2; sub(/^graylog-/,"",n); sub(/-repository.*/,"",n); print n; exit}')
  must "${APT_ENV[@]}" apt-get install -y -o Dpkg::Options::=--force-confnew "$deb"
  (( DRY )) || REPO_PENDING=${PREV_REPO:-}
  if (( ! DRY )); then
    awk -v m="$minor" '{for (i=1;i<NF;i++) if ($i=="stable" && $(i+1)==m) f=1} END{exit !f}' "$LISTFILE" \
      || die "$LISTFILE does not say 'stable $minor'. Check it before continuing (nothing unheld yet)."
    say "$LISTFILE: $(grep -E 'stable' "$LISTFILE" | head -n 1)"
    say "Repository packages: $(dpkg -l 2>/dev/null | awk '/^ii +graylog-[0-9.]+-repository/{print $2}' | tr '\n' ' ')"
    rm -rf "$dir"
  fi
  must apt-get update
}

do_hop() { # idx total minor
  local idx=$1 total=$2 minor=$3 sver dver="" row mmin mmax
  if (( DRY )); then set_phase "Preview $idx/$total to $minor"; else set_phase "Hop $idx/$total to $minor"; fi
  if [[ $minor == "$CUR_MINOR" ]]; then hdr "Hop $idx of $total: patch update within $minor"; else hdr "Hop $idx of $total: to $minor"; hop_warn "$minor"; fi
  info "Expect a log gap of about 5 to 10 minutes (UDP syslog is not buffered)."
  if row=$(hop_row "$minor"); then
    IFS='|' read -r _ mmin mmax _ <<<"$row"
    mongo_check "$minor" "$mmin" "$mmax"
  else
    warn "Graylog $minor is not verified by this tool (MongoDB range and upgrade notes unknown)."
    ask "Continue with $minor anyway?" N "only after reading the $minor upgrade notes" || die "Declined unverified hop $minor."
  fi
  ask "Start hop $idx: upgrade to $minor (newest $minor.x is resolved after the repo swap)?" Y recommended || { say "Stopped before hop $idx."; exit 0; }
  HOP_START=$(date +%s)
  HOP_SLOG_MARK=$(log_mark "$SLOG"); HOP_DLOG_MARK=$(log_mark "$DLOG")

  swap_repo "$minor"
  resolve_version graylog-server "$minor"; sver=$RESOLVED
  if (( HAS_DN )); then resolve_version graylog-datanode "$minor"; dver=$RESOLVED; fi
  [[ -n $sver ]] || die "Could not resolve the target version."
  (( ! HAS_DN )) || [[ -n $dver ]] || die "Could not resolve the Data Node version."
  say "Newest $minor.x in the repo: graylog-server=$sver${dver:+ graylog-datanode=$dver}"

  UNHELD=1   # from here on the EXIT trap restores holds on any exit
  must apt-mark unhold "${PKGS[@]}"
  if [[ $(pkgver graylog-server) == "$sver" ]]; then
    say "graylog-server already at $sver, not reinstalling."
    REPO_PENDING=""
    must systemctl start graylog-server
    status_refresh
    wait_stage 300 "lbstatus ALIVE" "$SLOG" - alive
  else
    # Simulate and confirm BEFORE stopping the server, so a refusal leaves it running.
    simulate_install graylog-server "$sver"
    ask "Upgrade graylog-server to $sver (stops the server now)?" Y recommended || die "Declined graylog-server upgrade."
    if [[ $(systemctl is-active graylog-server) == active ]]; then
      must systemctl stop graylog-server
    fi
    (( DRY )) || SERVER_STOPPED=1
    must "${APT_ENV[@]}" apt-get install -y "${APT_OPTS[@]}" "graylog-server=$sver"
    REPO_PENDING=""
    must systemctl daemon-reload
    SLOG_MARK=$(log_mark "$SLOG"); SRV_START_SECS=$SECONDS; FALLBACK_WARNED=0
    must systemctl start graylog-server
    SERVER_STOPPED=0
    status_refresh
    local hook=-; [[ $minor == 7.0 ]] && hook=preflight_hint
    wait_stage 600 "graylog-server up and running + lbstatus ALIVE" "$SLOG" "$hook" server_ready
  fi

  if (( HAS_DN )); then
    info "Data Node shows as outdated in the UI until the next step. That is expected."
    install_pkg graylog-datanode "$dver"
    must systemctl daemon-reload
    must systemctl restart graylog-datanode
    status_refresh
    wait_stage 300 "Data Node ports 8999/9200/9300" "$DLOG" - datanode_ready
  else
    info "Self-managed search backend: not touched. Confirm it is supported for Graylog $minor."
  fi

  if (( DRY )); then dim "[dry-run] apt-mark hold ${PKGS[*]}"
  else restore_holds || die "Could not hold ${PKGS[*]}. Run: apt-mark hold ${PKGS[*]}"; fi
  UNHELD=0
  post_hop_checks "$minor" "$sver"
  hop_after "$minor"
  (( DRY )) || HOPS_DONE=$((HOPS_DONE + 1))
}

# ---- Optional backup
do_backup() {
  hdr "Backup"
  ask "Take config copies and a mongodump now? (answer n if a backup already exists)" Y recommended || { say "Backup skipped."; return 0; }
  must install -d -m 700 -o root -g root "$BK"
  must cp -p "$CONF" "$BK/server.conf"
  local f
  for f in /etc/graylog/datanode/datanode.conf:datanode.conf /etc/default/graylog-server:default-graylog-server "$LISTFILE":graylog.list; do
    if [[ -e ${f%%:*} ]]; then must cp -p "${f%%:*}" "$BK/${f##*:}"; else say "(not found, skipped: ${f%%:*})"; fi
  done
  if (( ! DRY )); then
    dpkg -l 2>/dev/null | grep -E 'graylog|mongodb' >"$BK/packages-before.txt"
    apt-mark showhold >"$BK/holds-before.txt"
  fi
  if ! command -v mongodump >/dev/null; then
    warn "mongodump not found. Not adding packages mid-change. Rely on the Hyper-V checkpoint and note it in the ticket."
  elif [[ $(grep -cE 'mongodb_uri[[:space:]]*=.*@' "$CONF") -ge 1 ]]; then
    if (( DRY )); then dim "[dry-run] mongodump with the URI from server.conf via a temporary 600 config file (URI never on the command line or in the log)"
    else
      local uri cfg=$BK/.mongodump.cfg
      uri=$(sed -nE 's/^[[:space:]]*mongodb_uri[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$CONF" | tail -n 1)
      [[ -n $uri ]] || die "Could not read mongodb_uri from $CONF."
      ( umask 077; printf "uri: '%s'\n" "${uri//\'/\'\'}" >"$cfg" )
      say "+ mongodump --quiet --config <temp file> --out $BK/mongodump"
      mongodump --quiet --config "$cfg" --out "$BK/mongodump" || { rm -f "$cfg"; die "mongodump failed."; }
      rm -f "$cfg"
    fi
  else
    must mongodump --quiet --out "$BK/mongodump"
  fi
  must chmod -R go-rwx "$BK"
  (( DRY )) || { find "$BK" -type f -exec chmod 600 {} +; ls -la "$BK"; du -sh "$BK"/mongodump/graylog 2>/dev/null; }
  say "Backup folder $BK stays on the server only (contains password_secret). Never attach it anywhere."
}

# ---- Discovery (read-only, public Graylog repo index)
newest_stable() { # Packages file -> newest non-prerelease graylog-server version
  awk '/^Package:/{p=$2} /^Version:/{if (p=="graylog-server") print $2}' "$1" | grep -Ev '\.(alpha|beta|rc)\.' | sort -V | tail -n 1
}
PROBE_CODE=000; PROBE_TMP=""
probe_minor() { # minor -> sets PROBE_CODE; on 200 records DISC and LATEST and ONLINE
  PROBE_CODE=$(curl -sL --connect-timeout 5 --max-time 20 -o "$PROBE_TMP" -w '%{http_code}' "$REPO_BASE/$1/binary-amd64/Packages" 2>/dev/null) || PROBE_CODE=000
  if [[ $PROBE_CODE == 200 ]]; then ONLINE=1; DISC+=("$1"); LATEST[$1]=$(newest_stable "$PROBE_TMP"); fi
}
discover_repo() { # probes EVERY table minor from the installed one up (no early stop), then unknown newer minors until 404
  local h m last maj min n=0 jumped=0 first=1
  PROBE_TMP=$(mktemp)
  for h in "${HOPS[@]}"; do
    m=${h%%|*}; last=$m
    dpkg --compare-versions "$m" lt "$CUR_MINOR" && continue
    probe_minor "$m"
    if (( first )) && [[ $PROBE_CODE == 000 ]]; then rm -f "$PROBE_TMP"; return 0; fi   # offline: stop early
    first=0
  done
  maj=${last%%.*}; min=${last##*.}
  while (( n++ < 30 )); do
    min=$((min + 1)); m=$maj.$min
    probe_minor "$m"
    case $PROBE_CODE in
      200) jumped=0 ;;
      404) (( jumped )) && break; jumped=1; maj=$((maj + 1)); min=-1 ;;
      *)   break ;;
    esac
  done
  rm -f "$PROBE_TMP"
}
minor_status() { # verified | newer | unverified
  local row; row=$(hop_row "$1") || { printf unverified; return; }
  [[ ${row##*|} == newer ]] && printf newer || printf verified
}
selectable() { # online: needs a stable release in the repo; offline: table minors only
  if (( ONLINE )); then [[ -n ${LATEST[$1]:-} ]]; else hop_row "$1" >/dev/null; fi
}
show_path() {
  local m st lat mk rc
  hdr "Upgrade path (installed: graylog-server $SVER)"
  say "Latest available $( ((ONLINE)) && echo '(live from the Graylog repo index)' || echo '(OFFLINE: built-in table only, versions resolve after the repo swap)')"
  for m in "${ALL[@]}"; do
    dpkg --compare-versions "$m" lt "$CUR_MINOR" && continue
    st=$(minor_status "$m")
    if (( ONLINE )); then
      if [[ -n ${LATEST[$m]:-} ]]; then lat=${LATEST[$m]}
      elif [[ " ${DISC[*]} " == *" $m "* ]]; then lat="pre-release only, not offered"
      else lat="MISSING from repo index"; fi
    else lat="-"; fi
    rc=""
    if [[ $m == "$CUR_MINOR" ]]; then rc=$C_BOLD
    elif [[ $m == "$RECOMMENDED" ]]; then rc=$C_GRN
    elif [[ $lat == "MISSING from repo index" ]]; then rc=$C_RED
    elif [[ $st == newer ]]; then rc=$C_YEL
    elif [[ $st == unverified || $lat == pre-release* ]]; then rc=$C_DIM
    fi
    case $st in verified) st="verified";; newer) st="newer, not recommended yet";; *) st="not verified by this tool";; esac
    mk=""
    [[ $m == "$CUR_MINOR" ]] && mk+="  <-- you are here ($SVER)"
    [[ $m == "$RECOMMENDED" ]] && mk+="  [recommended target]"
    [[ $m == "$TARGET" && $m != "$CUR_MINOR" ]] && mk+="  [selected target]"
    printf '%s  %-5s newest %-30s %s%s%s\n' "$rc" "$m" "$lat" "$st" "$mk" "$C_RST"
  done
}
valid_target() { # X.Y that exists in the repo (or table when offline) and is newer than the installed minor
  [[ $1 =~ ^[0-9]+\.[0-9]+$ ]] || return 1
  selectable "$1" || return 1
  dpkg --compare-versions "$1" gt "$CUR_MINOR"
}
build_plan() {
  local m; PLAN=(); MISSING=()
  for m in "${ALL[@]}"; do
    dpkg --compare-versions "$m" gt "$TARGET" && continue
    if dpkg --compare-versions "$m" gt "$CUR_MINOR"; then
      if selectable "$m"; then PLAN+=("$m"); else MISSING+=("$m"); fi
    elif [[ $m == "$CUR_MINOR" ]]; then
      if (( HAS_DN )) && dpkg --compare-versions "$DM" lt "$m"; then PLAN+=("$m")           # Data Node lagging
      elif (( ONLINE )) && [[ -n ${LATEST[$m]:-} ]] && dpkg --compare-versions "$SVER" lt "${LATEST[$m]}"; then PLAN+=("$m")   # patch update
      fi
    fi
  done
}
check_plan() { # never skip a minor silently
  (( ${#MISSING[@]} )) || return 0
  say "$(f_stop "in the path but missing from Graylog's repo index (or pre-release only): ${MISSING[*]}.")"
  say "This tool will not skip a minor. Check connectivity, or pick a lower target (option 3)."
  return 1
}
choose_target() {
  local ans st
  while :; do
    printf '%sTarget minor%s [%s%s%s, recommended]: ' "$C_BOLD" "$C_RST" "$C_GRN" "$RECOMMENDED" "$C_RST"
    read -r ans </dev/tty || die "No terminal input."
    ans=${ans:-$RECOMMENDED}
    printf 'PROMPT: target -> %s\n' "$ans" >>"$LOG"
    valid_target "$ans" || { say "Not available or not newer than $CUR_MINOR. Pick a minor from the list."; continue; }
    st=$(minor_status "$ans")
    if [[ $st != verified ]]; then
      warn "$ans is $st."
      ask "Use $ans as the target anyway?" N "not recommended" || continue
    fi
    TARGET=$ans; return 0
  done
}

# ---- Pre-checks and gates
precheck_config() { # runbook pre-checks 9 to 11
  local heap
  heap=$(sed -nE 's/^[[:space:]]*opensearch_heap[[:space:]]*=[[:space:]]*([^#]*[^#[:space:]])[[:space:]]*(#.*)?$/\1/p' /etc/graylog/datanode/datanode.conf 2>/dev/null | tail -n 1)
  if [[ -n $heap && ! $heap =~ ^[0-9]+[kKmMgG]$ ]]; then PRE7+=("opensearch_heap is '$heap' in datanode.conf (7.x needs a plain size such as 4g or 4096m)"); fi
  if grep -qE '^[[:space:]]*JAVA=' /etc/default/graylog-server 2>/dev/null; then PRE7+=("JAVA= override in /etc/default/graylog-server (7.x bundles Java 21; remove the override first)"); fi
  if grep -qiE '^[[:space:]]*skip_preflight_checks[[:space:]]*=[[:space:]]*true' "$CONF" 2>/dev/null; then PRE_ALL+=("skip_preflight_checks=true in server.conf (remove it first)"); fi
}
in_mux() { # tmux or screen anywhere in the process ancestry (sudo strips $TMUX and $STY)
  local pid=$$ c n=0
  [[ -n ${TMUX:-}${STY:-} ]] && return 0
  while (( pid > 1 && n++ < 20 )); do
    c=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    [[ $c =~ ^(tmux|screen|SCREEN) ]] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
    [[ -n $pid ]] || break
  done
  return 1
}
mongo_path_check() { # whole path up front
  local m row mmin mmax bad=""
  hdr "MongoDB check for the whole path (built-in table ranges)"
  mongo_version; say "Installed MongoDB: ${MONGO_VER:-not detected}"
  if [[ -z $MONGO_VER ]]; then
    (( DRY )) && die "MongoDB version not detected. Preview stops here (it will not assume it is fine)."
    ask "Continue without a MongoDB check?" N "answer y only if you have verified it" || die "MongoDB version not verified."
    return 0
  fi
  for m in "${PLAN[@]}"; do
    if row=$(hop_row "$m"); then
      IFS='|' read -r _ mmin mmax _ <<<"$row"
      if dpkg --compare-versions "$MONGO_VER" lt "$mmin" || dpkg --compare-versions "$MONGO_VER" gt "$mmax"; then
        say "  $m: needs $mmin to ${mmax%.9999}.x  OUTSIDE"; bad+=" $m"
      else say "  $m: needs $mmin to ${mmax%.9999}.x  ok"; fi
    else say "  $m: not in the built-in table (not verified)"; fi
  done
  [[ -z $bad ]] || die "MongoDB $MONGO_VER is outside the built-in table range for:$bad. Nothing was changed. Upgrade MongoDB separately, or pick a lower target (option 3) that stops before that hop."
}
health_gate() {
  local reasons=() svc free_kb need_kb mongo_kb dbp r ans
  alive || reasons+=("lbstatus is not ALIVE")
  for svc in mongod "${PKGS[@]}"; do [[ $(systemctl is-active "$svc" 2>/dev/null) == active ]] || reasons+=("$svc is not active"); done
  free_kb=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}'); free_kb=${free_kb:-0}
  dbp=$(sed -nE 's/^[[:space:]]*dbPath:[[:space:]]*([^#[:space:]]+).*/\1/p' /etc/mongod.conf 2>/dev/null | head -n 1); dbp=${dbp:-/var/lib/mongodb}
  mongo_kb=$(du -sk "$dbp" 2>/dev/null | awk '{print $1}'); mongo_kb=${mongo_kb:-0}
  need_kb=$((5 * 1024 * 1024)); (( mongo_kb * 2 > need_kb )) && need_kb=$((mongo_kb * 2))
  (( free_kb < need_kb )) && reasons+=("free space on / is $((free_kb / 1024)) MB, need $((need_kb / 1024)) MB (5 GB or 2x MongoDB data at $dbp)")
  (( ${#reasons[@]} )) || { ok "Health gate: ok (lbstatus ALIVE, services active, $((free_kb / 1024)) MB free on /)."; return 0; }
  for r in "${reasons[@]}"; do warn "Health gate: $r"; done
  if (( DRY )); then dim "[preview] a real run would stop here unless you type yes."; return 0; fi
  printf '%sType yes to continue anyway, anything else stops:%s ' "$C_BOLD" "$C_RST"
  read -r ans </dev/tty || die "No terminal input."
  printf 'PROMPT: health gate override -> %s\n' "$ans" >>"$LOG"
  [[ $ans == yes ]] || die "Stopped by the health gate."
}
gates() {
  local m has7=0 r virt
  for m in "${PLAN[@]}"; do dpkg --compare-versions "$m" ge 7.0 && has7=1; done
  mongo_path_check
  if (( ${#PRE_ALL[@]} )); then for r in "${PRE_ALL[@]}"; do warn "$r"; done; die "Fix the pre-check item(s) above first."; fi
  if (( has7 && ${#PRE7[@]} )); then for r in "${PRE7[@]}"; do warn "$r"; done; die "Fix the pre-check item(s) above before a 7.x hop (or pick a target below 7.0)."; fi
  health_gate
  virt=$(systemd-detect-virt 2>/dev/null || true); say "Virtualisation: ${virt:-unknown}"
  ask "Have you taken a VM checkpoint or snapshot (or a full backup if this is not a VM)?" N "required" || die "Take a checkpoint or backup first, then run this tool again."
}
walkthrough() {
  local n=0 m
  say ""; say "Planned hops:"
  for m in "${PLAN[@]}"; do n=$((n + 1)); if [[ $m == "$CUR_MINOR" ]]; then say "  $n. patch update within $m"; else say "  $n. to $m"; fi; done
  info "Never touched: MongoDB, search backend, Sidecar, kernel, other packages."
  gates
  do_backup
  n=0
  for m in "${PLAN[@]}"; do
    n=$((n + 1))
    do_hop "$n" "${#PLAN[@]}" "$m"
    if (( n < ${#PLAN[@]} )); then
      ask "Continue to next hop?" N "answer y only after the UI checklist passes" || { say "Paused after hop $n. Packages are held."; exit 0; }
    fi
  done
}

# ---- Main: scan screen
build_pkgs() { PKGS=(graylog-server); HAS_DN=0; [[ -n $(pkgver graylog-datanode) ]] && { HAS_DN=1; PKGS+=(graylog-datanode); }; return 0; }

pin_init || banner
terms_gate
set_phase Start
hdr "shuriken Graylog upgrade $(date '+%F %T')"
if ! in_mux; then
  warn "Not running inside tmux or screen. If this terminal closes, the upgrade can be interrupted halfway."
  ask "Continue without tmux/screen?" N "recommended: run  tmux new -s graylog  first" || die "Start tmux (tmux new -s graylog) and run again."
fi
[[ -n $(pkgver graylog-server) ]] || die "graylog-server is not installed (this tool supports apt installs only)."
build_pkgs
HELD_START=" $(apt-mark showhold | tr '\n' ' ') "
SVER=$(pkgver graylog-server); DVER=$(pkgver graylog-datanode)
START_SVER=$SVER; START_DVER=$DVER
CUR=${SVER#*:}; CUR=${CUR%%-*}; CUR_MINOR=${CUR%.*}
DM=${DVER#*:}; DM=${DM%%-*}; DM=${DM%.*}
set_phase Scan
hdr "Scan"
# shellcheck source=/dev/null
say "OS:            $(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"
say "Graylog:       graylog-server $SVER${DVER:+, graylog-datanode $DVER}"
say "Held:          $(apt-mark showhold | tr '\n' ' ')"
mongo_version; say "MongoDB:       ${MONGO_VER:-not detected}"
if (( HAS_DN )); then
  say "Search backend: Graylog Data Node $DVER"
else
  say "Search backend: self-managed. Found by dpkg: $(dpkg -l 2>/dev/null | awk '/^ii +(opensearch|elasticsearch)( |:)/{print $2" "$3}' | tr '\n' ' ')(blank = tarball, container or remote)"
  warn "No graylog-datanode: Data Node steps are skipped and the backend is NOT upgraded."
  warn "Graylog up to 7.1 supports OpenSearch up to 2.19.6. Elasticsearch and OpenSearch 1.x are deprecated from 7.0. Verify yours before each hop."
fi
say "Services:      $(systemctl is-active mongod "${PKGS[@]}" 2>&1 | tr '\n' ' ')(mongod ${PKGS[*]})"
load_health_url
if alive; then say "lbstatus:      ${C_GRN}ALIVE${C_RST} ($HEALTH_URL)"; else warn "lbstatus is not ALIVE ($HEALTH_URL). Investigate first."; fi
say "Disk free:"; df -h --output=target,avail,pcent / /var 2>/dev/null | awk '!seen[$0]++' | sed 's/^/                /'
say "RAM:           $(free -h 2>/dev/null | awk 'NR==2{print "total "$2", used "$3", available "$7}')"
precheck_config
say "Pre-check 9 (opensearch_heap):  $(printf '%s\n' "${PRE7[@]:-}" | grep -c heap | sed 's/^0$/ok/;s/^[1-9].*/PROBLEM/')"
say "Pre-check 10 (JAVA= override):  $(printf '%s\n' "${PRE7[@]:-}" | grep -c JAVA= | sed 's/^0$/ok/;s/^[1-9].*/PROBLEM/')"
say "Pre-check 11 (skip_preflight):  $( (( ${#PRE_ALL[@]} )) && echo PROBLEM || echo ok)"
for r in "${PRE7[@]}" "${PRE_ALL[@]}"; do warn "$r"; done
dpkg --compare-versions "$CUR_MINOR" ge 6.0 || die "Graylog $CUR_MINOR is older than 6.0. This tool starts at 6.0. Upgrade to 6.0 by hand first."
SNAP=$(mktemp); listeners >"$SNAP"
say "Listener snapshot: $(wc -l <"$SNAP") TCP/UDP listeners below port $EPH_LO."

info "Checking Graylog's repo index for the latest versions ..."
discover_repo
if (( ! ONLINE )); then warn "Could not reach the Graylog repo index (no internet?). Using the built-in table; exact versions resolve after each repo swap."; fi
HOP_MINORS=(); for h in "${HOPS[@]}"; do dpkg --compare-versions "${h%%|*}" lt "$CUR_MINOR" || HOP_MINORS+=("${h%%|*}"); done
if (( ONLINE )); then mapfile -t ALL < <(printf '%s\n' "${DISC[@]}" "${HOP_MINORS[@]}" | sort -uV)
else mapfile -t ALL < <(printf '%s\n' "${HOP_MINORS[@]}" | sort -uV); fi
for h in "${HOPS[@]}"; do [[ ${h##*|} == newer ]] || RECOMMENDED=${h%%|*}; done   # newest verified minor
if dpkg --compare-versions "$RECOMMENDED" gt "$CUR_MINOR"; then TARGET=$RECOMMENDED; else TARGET=$CUR_MINOR; fi
if [[ -n $TO ]]; then
  valid_target "$TO" || die "--to $TO is not an available minor newer than $CUR_MINOR."
  if [[ $(minor_status "$TO") != verified ]]; then
    ask "$TO is not verified or recommended. Use it as the target anyway?" N "not recommended" || die "Declined target $TO."
  fi
  TARGET=$TO
fi

if (( PREVIEW_ONLY )); then
  build_plan; show_path
  check_plan || exit 1
  (( ${#PLAN[@]} )) || { say "Nothing to do: $SVER is at or past target $TARGET."; exit 0; }
  set_phase Preview; walkthrough; ok "Preview finished. Nothing was changed."; set_phase Done; exit 0
fi

while :; do
  build_plan; show_path
  set_phase Menu
  say ""
  if (( ${#PLAN[@]} )); then say "Plan: $(printf '%s ' "${PLAN[@]}")"; else say "Nothing to do for target $TARGET ($SVER is at or past it). Use 3 to pick another target."; fi
  say "  ${C_YEL}[1]${C_RST} Upgrade along this path (recommended after a Preview)"
  say "  ${C_BOLD}${C_GRN}[2] Preview only (default: shows every step, changes nothing)${C_RST}"
  say "  [3] Change target"
  say "  [4] Quit"
  printf '%sChoose 1-4%s [default %s2 = Preview%s, the safer first choice]: ' "$C_BOLD" "$C_RST" "$C_GRN" "$C_RST"
  read -r ans </dev/tty || die "No terminal input."
  ans=${ans:-2}; printf 'PROMPT: menu -> %s\n' "$ans" >>"$LOG"
  case $ans in
    1|2) if (( ! ${#PLAN[@]} )); then say "Nothing to do for this target."; continue; fi
         check_plan || continue
         if [[ $ans == 2 ]]; then
           set_phase Preview
           if ( DRY=1; walkthrough ); then ok "Preview finished. Nothing was changed. Back at the menu."
           else say "Preview stopped (see the reason above). Nothing was changed. Back at the menu."; fi
         else STARTED_REAL=1; walkthrough; set_phase Done; exit 0; fi ;;
    3) choose_target ;;
    4) say "Quit. Nothing was changed."; exit 0 ;;
    *) say "Choose 1, 2, 3 or 4." ;;
  esac
done
