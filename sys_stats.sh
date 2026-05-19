#!/bin/sh
# tmux pane-border / status — cross-platform system stats (macOS + Linux Ubuntu 22+).
#
# Design:
#   - Async cache: tmux gets the cached output immediately (~15ms),
#     a background fork refreshes the cache.
#   - Locking: mkdir + PID file; trap EXIT only removes a lock we own
#     (prevents stale-eviction races).
#   - Stale-lock heartbeat: `touch` the lock during long collection so
#     a long-running sample doesn't get mis-classified as a crash leftover.
#   - mktemp avoids symlink attacks on the cache file; write failures
#     surface an explicit "!ERR" segment instead of going silent.
#   - Paths are per-UID under $TMPDIR to harden against multi-user DoS.
#   - IP field: LAN IP probed in real time; public IP from a 30-min async
#     cache (refreshed by the background fork via curl ifconfig.me).
#     A stale or missing cache degrades to LAN-only — no synchronous curl.
#     Worst-case lag: macOS configd dead (~5s) or DNS hang (~10s, background
#     only — never blocks tmux rendering, just delays the pub IP refresh).
#
# Output fields: IP | CPU% | MEM% | LOAD% (normalized to core count) | process count

# --- Paths: per-UID inside $TMPDIR ---
_uid=$(id -u 2>/dev/null) || _uid=unknown
[ -z "$_uid" ] && _uid=unknown
_tmp="${TMPDIR:-/tmp}"
CACHE="$_tmp/tmux_sys_stats.${_uid}.cache"
LOCK="$_tmp/tmux_sys_stats.${_uid}.lock"
# Note: pub IP cache holds the machine's public IP (PII-ish). Per-UID path means
# content is readable only by this UID. The script also pings ifconfig.me /
# icanhazip.com once every 30 min to refresh — disable by removing the curl
# block in Step 4 if you don't want that traffic.
PUB_IP_CACHE="$_tmp/tmux_sys_stats.${_uid}.pubip"
TTL=5
PUB_IP_TTL=1800  # public IP cache TTL: 30 minutes (rarely changes)
STALE_LOCK_SEC=60  # locks older than this are treated as crash leftovers (with heartbeat margin)

# Lock locale so uptime / awk parsing isn't affected by localized labels.
export LANG=C LC_ALL=C

# --- IP probe: LAN IP real-time + public IP from cache (30-min TTL) ---
# Output format:
#   <LAN IP>                  public IP unavailable (no cache yet / curl missing / offline)
#   <LAN IP> → <Public IP>    both available and different
#   <Public IP>               LAN probe failed but public IP cached
#   ?                         all probes failed
#
# Public IP is refreshed asynchronously by the background sample collector
# (Step 4) when the cache is older than PUB_IP_TTL. The main path NEVER calls
# curl synchronously — so a network outage cannot block tmux rendering.
#
# Scope note: POSIX sh has no `local`. Variables prefixed with `_` (e.g. `_OS`,
# `_lan`) are convention-only and leak into the main shell after the call.
# This is intentional — the background subshell (Step 4) uses different names
# (OS, cpu, mem, ...) so there's no collision.
get_ip() {
    _OS=$(uname -s)
    _lan=""

    # 1) Source IP of the default route.
    #    Linux: `ip route get` auto-skips docker / vpn internal IPs (uses real default route).
    #    macOS: if the default route points at a TUN device (Tailscale/Mullvad VPN),
    #           `ipconfig getifaddr` returns nothing → falls through to step 2 (en0-en7),
    #           giving the physical LAN IP. This is intentional but not "auto-skip".
    if [ "$_OS" = "Darwin" ]; then
        _iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
        [ -n "$_iface" ] && _lan=$(ipconfig getifaddr "$_iface" 2>/dev/null)
    else
        _lan=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {
            for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}
        }')
    fi

    # 2) macOS fallback: iterate common interfaces.
    if [ -z "$_lan" ] && [ "$_OS" = "Darwin" ]; then
        for i in 0 1 2 3 4 5 6 7; do
            _cand=$(ipconfig getifaddr "en$i" 2>/dev/null)
            if [ -n "$_cand" ]; then _lan="$_cand"; break; fi
        done
    fi

    # 3) Linux fallback: first IP from `hostname -I`.
    if [ -z "$_lan" ] && [ "$_OS" != "Darwin" ]; then
        _lan=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # 4) Public IP: read from cache only (background collector refreshes it).
    _pub_ip=""
    if [ -f "$PUB_IP_CACHE" ]; then
        _pub_ip=$(cat "$PUB_IP_CACHE" 2>/dev/null)
    fi

    # 5) Emit.
    if [ -n "$_lan" ] && [ -n "$_pub_ip" ] && [ "$_lan" != "$_pub_ip" ]; then
        printf '%s → %s' "$_lan" "$_pub_ip"
    elif [ -n "$_lan" ]; then
        printf '%s' "$_lan"
    elif [ -n "$_pub_ip" ]; then
        printf '%s' "$_pub_ip"
    else
        printf '?'
    fi
}

# --- Step 1: emit IP (real-time) + cached stats (CPU/MEM/LOAD/procs) ---
printf '#[bg=colour235,fg=cyan] IP: %s #[default]' "$(get_ip)"
if [ -f "$CACHE" ]; then
    cat "$CACHE"
else
    printf '#[fg=colour244] (loading) #[default]'
fi

# --- Step 2: decide whether a refresh is due ---
need_refresh=1
if [ -f "$CACHE" ]; then
    mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    [ "$age" -lt "$TTL" ] && need_refresh=0
fi
[ "$need_refresh" = 0 ] && exit 0

# --- Step 3: stale-lock recovery (with ownership check) ---
# Only reclaim a lock if (a) it's older than the threshold AND (b) the recorded
# PID is actually dead. This prevents wrongly evicting a slow legitimate sample.
if [ -d "$LOCK" ]; then
    lock_mtime=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    lock_age=$(( $(date +%s) - lock_mtime ))
    if [ "$lock_age" -gt "$STALE_LOCK_SEC" ]; then
        old_pid=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -z "$old_pid" ] || ! kill -0 "$old_pid" 2>/dev/null; then
            rm -f "$LOCK/pid" 2>/dev/null
            rmdir "$LOCK" 2>/dev/null
        fi
    fi
fi

# --- Step 4: acquire lock and fork background collector ---
mkdir "$LOCK" 2>/dev/null || exit 0
# Write the PID from the parent shell (POSIX: $$ stays the main shell PID in subshells).
echo $$ > "$LOCK/pid" 2>/dev/null
my_pid=$$

(
    # Only remove a lock we still own.
    cleanup() {
        if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$my_pid" ]; then
            rm -f "$LOCK/pid" 2>/dev/null
            rmdir "$LOCK" 2>/dev/null
        fi
    }
    trap cleanup EXIT

    # Force 0600 on any file we create here (cache + pubip via mktemp + mv).
    # This makes the "only readable by this UID" promise explicit instead of
    # relying on mktemp's default behavior, which varies across implementations.
    umask 077

    export LANG=C LC_ALL=C
    OS=$(uname -s)
    err=0  # set to 1 if any field fails — triggers the visible !ERR marker

    # ============================================================
    # Public IP refresh (30-min TTL)
    # Runs only when cache is missing or expired. Failures (no curl,
    # network down, HTTP error) leave the previous cache untouched so
    # we degrade to "LAN-only" instead of breaking the bar.
    # ============================================================
    pubip_needs_refresh=1
    if [ -f "$PUB_IP_CACHE" ]; then
        pubip_mtime=$(stat -f %m "$PUB_IP_CACHE" 2>/dev/null || stat -c %Y "$PUB_IP_CACHE" 2>/dev/null || echo 0)
        pubip_age=$(( $(date +%s) - pubip_mtime ))
        [ "$pubip_age" -lt "$PUB_IP_TTL" ] && pubip_needs_refresh=0
    fi
    if [ "$pubip_needs_refresh" = 1 ] && command -v curl >/dev/null 2>&1; then
        # Primary endpoint, then a backup. -fsS = fail on HTTP error, silent, but show errors (we eat them via 2>/dev/null).
        pub_new=$(curl -fsS --max-time 2 https://ifconfig.me 2>/dev/null)
        [ -z "$pub_new" ] && pub_new=$(curl -fsS --max-time 2 https://ipv4.icanhazip.com 2>/dev/null)
        # Trim whitespace/newlines and validate as IPv4 (rejects HTML error pages
        # AND semantically invalid IPs like 999.999.999.999 — each octet 0-255).
        pub_new=$(printf '%s' "$pub_new" | tr -d '[:space:]')
        if printf '%s' "$pub_new" | grep -qE '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$'; then
            # Atomic write via mktemp (same anti-symlink discipline as the stats cache).
            pubtmp=$(mktemp "${PUB_IP_CACHE}.XXXXXX" 2>/dev/null)
            if [ -n "$pubtmp" ]; then
                if printf '%s' "$pub_new" > "$pubtmp" 2>/dev/null \
                   && mv "$pubtmp" "$PUB_IP_CACHE" 2>/dev/null; then
                    :
                else
                    rm -f "$pubtmp" 2>/dev/null
                fi
            fi
        fi
    fi

    # Heartbeat: pub IP probe may take up to ~10s on macOS with broken DNS
    # (getaddrinfo ignores curl's --max-time on system-level DNS hangs);
    # touch the lock so it isn't reclaimed by another instance.
    touch "$LOCK" 2>/dev/null

    # ============================================================
    # CPU usage
    # ============================================================
    if [ "$OS" = "Darwin" ]; then
        cpu=$(top -l 1 -n 0 2>/dev/null \
              | awk '/CPU usage/ {gsub(/%/,""); printf "%d", $3 + $5; exit}')
    else
        read_cpu_stat() {
            awk '/^cpu / {
                if (NF < 5) {print ""; exit}
                idle=$5; total=0
                for (i=2; i<=NF; i++) total += $i
                print total" "idle; exit
            }' /proc/stat 2>/dev/null
        }
        s1=$(read_cpu_stat)
        sleep 1
        s2=$(read_cpu_stat)
        if [ -n "$s1" ] && [ -n "$s2" ]; then
            cpu=$(echo "$s1 $s2" | awk '{
                dt = $3 - $1; di = $4 - $2
                if (dt > 0) printf "%d", (1 - di/dt) * 100
                else print ""
            }')
        else
            cpu=""
        fi
    fi
    if [ -z "$cpu" ]; then cpu=0; err=1; fi

    # Heartbeat: CPU sampling can take ~1s; touch the lock so it isn't reclaimed.
    touch "$LOCK" 2>/dev/null

    # ============================================================
    # Memory usage
    # ============================================================
    if [ "$OS" = "Darwin" ]; then
        page_size=$(sysctl -n hw.pagesize 2>/dev/null)
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        if [ -n "$page_size" ] && [ "$page_size" -gt 0 ] && [ -n "$total_bytes" ]; then
            total_pages=$((total_bytes / page_size))
            vm=$(vm_stat 2>/dev/null)
            pg() { echo "$vm" | awk -v k="$1:" 'index($0, k) {gsub(/\./,"",$NF); print $NF; exit}'; }
            active=$(pg "Pages active")
            wired=$(pg "Pages wired down")
            comp=$(pg "Pages occupied by compressor")
            : "${active:=0}"; : "${wired:=0}"; : "${comp:=0}"
            used_pages=$((active + wired + comp))
            if [ "$total_pages" -gt 0 ] && [ "$used_pages" -gt 0 ]; then
                mem=$((used_pages * 100 / total_pages))
            else
                mem=""
            fi
        else
            mem=""
        fi
    else
        mem=$(awk '
            /^MemTotal:/     {t=$2}
            /^MemAvailable:/ {a=$2}
            /^MemFree:/      {f=$2}
            END {
                if (t<=0) exit
                used = (a!="") ? t-a : (f!="") ? t-f : ""
                if (used != "") printf "%d", used*100/t
            }
        ' /proc/meminfo 2>/dev/null)
    fi
    if [ -z "$mem" ]; then mem=0; err=1; fi

    # ============================================================
    # Load average (1-min) — normalized to a percentage by core count
    # ============================================================
    if [ -r /proc/loadavg ]; then
        load=$(cut -d' ' -f1 /proc/loadavg)
    else
        load=$(uptime | awk -F'load averages?: ' '{print $2}' | awk '{print $1}')
    fi
    if [ "$OS" = "Darwin" ]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null)
    else
        cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null)
    fi
    : "${cores:=1}"
    [ "$cores" -lt 1 ] && cores=1
    load_pct=$(awk -v l="$load" -v c="$cores" 'BEGIN {
        if (l == "" || l ~ /[^0-9.]/) exit
        printf "%d", l * 100 / c
    }')
    if [ -z "$load_pct" ]; then load_pct=0; err=1; fi

    # ============================================================
    # Process count (portable: ps -A works on macOS and Linux)
    # ============================================================
    procs=$(ps -A 2>/dev/null | awk 'END {print NR - 1}')
    if [ -z "$procs" ] || [ "$procs" -le 0 ]; then procs=0; err=1; fi

    # ============================================================
    # Emit: mktemp guards against symlink races on $CACHE.new;
    # on write failure, surface an explicit !CACHE-* marker.
    # ============================================================
    if [ "$err" = 1 ]; then
        err_seg='#[fg=red,bold] !ERR '
    else
        err_seg=''
    fi

    tmpfile=$(mktemp "${CACHE}.XXXXXX" 2>/dev/null)
    if [ -z "$tmpfile" ]; then
        # mktemp failed — drop a visible error cache so the bar shows it.
        printf '#[fg=red,bold] !MKTEMP-ERR #[default]' > "$CACHE" 2>/dev/null
    else
        if printf '%s#[fg=colour244]│#[fg=green]  CPU %d%% #[fg=colour244]│#[fg=magenta]  MEM %d%% #[fg=colour244]│#[fg=yellow] 󰕮 LOAD %d%% #[fg=colour244]│#[fg=cyan]  %s #[default]' \
                "$err_seg" "$cpu" "$mem" "$load_pct" "$procs" \
                > "$tmpfile" 2>/dev/null \
           && mv "$tmpfile" "$CACHE" 2>/dev/null; then
            :  # success
        else
            rm -f "$tmpfile" 2>/dev/null
            printf '#[fg=red,bold] !CACHE-WRITE-ERR #[default]' > "$CACHE" 2>/dev/null
        fi
    fi
) </dev/null >/dev/null 2>&1 &

exit 0
