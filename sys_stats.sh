#!/bin/sh
# tmux pane-border / status 系统资源指标 — 跨平台 (macOS + Linux Ubuntu 22+)。
#
# 设计：
#   - 异步缓存：tmux 调用立即拿缓存 (~15ms)，后台 fork 采集新数据
#   - 锁：mkdir + PID 文件，trap EXIT 只清自己持有的锁（抗 stale 误清）
#   - stale-lock heartbeat：采集期间定期 touch 锁，避免长采集被误判残留
#   - 临时文件用 mktemp 防 symlink 攻击；写缓存失败时落显式 !ERR
#   - 每用户路径隔离（多用户机器抗 DoS）
#
# 输出字段：CPU% │ MEM% │ LOAD%（按本机核数标准化） │ 进程数

# --- 路径：在 TMPDIR 下用 UID 隔离 ---
_uid=$(id -u 2>/dev/null) || _uid=unknown
[ -z "$_uid" ] && _uid=unknown
_tmp="${TMPDIR:-/tmp}"
CACHE="$_tmp/tmux_sys_stats.${_uid}.cache"
LOCK="$_tmp/tmux_sys_stats.${_uid}.lock"
TTL=5
STALE_LOCK_SEC=60  # 锁目录超过此年龄视为崩溃残留（含 heartbeat 余量）

# 稳定 locale，避免 uptime / awk 解析受本地化影响
export LANG=C LC_ALL=C

# --- 步骤 1: 立即输出缓存 ---
if [ -f "$CACHE" ]; then
    cat "$CACHE"
else
    printf '#[fg=colour244] (loading) #[default]'
fi

# --- 步骤 2: 判断刷新窗口 ---
need_refresh=1
if [ -f "$CACHE" ]; then
    mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    [ "$age" -lt "$TTL" ] && need_refresh=0
fi
[ "$need_refresh" = 0 ] && exit 0

# --- 步骤 3: stale lock 回收（带所有权校验） ---
# 关键：只在 (a) 锁年龄超阈值 且 (b) 锁里记录的 PID 实际已死 时清理。
# 这样避免合法长采集被误清。
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

# --- 步骤 4: 取锁并 fork 后台采集 ---
mkdir "$LOCK" 2>/dev/null || exit 0
# 父 shell 立即写 PID（POSIX 规定 subshell 中 $$ 仍为 main shell PID）
echo $$ > "$LOCK/pid" 2>/dev/null
my_pid=$$

(
    # EXIT 时只删自己持有的锁
    cleanup() {
        if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$my_pid" ]; then
            rm -f "$LOCK/pid" 2>/dev/null
            rmdir "$LOCK" 2>/dev/null
        fi
    }
    trap cleanup EXIT

    export LANG=C LC_ALL=C
    OS=$(uname -s)
    err=0  # 任一字段采集失败置 1，触发可见错误标记

    # ============================================================
    # CPU 使用率
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

    # Heartbeat：CPU 采样可能要 1 秒，touch 锁防误清
    touch "$LOCK" 2>/dev/null

    # ============================================================
    # 内存占用率
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
    # Load average (1 分钟) → 按本机核数标准化为百分比
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
    # 进程数（兼容 macOS / Linux）
    # ============================================================
    procs=$(ps -A 2>/dev/null | awk 'END {print NR - 1}')
    if [ -z "$procs" ] || [ "$procs" -le 0 ]; then procs=0; err=1; fi

    # ============================================================
    # 输出：用 mktemp 防 symlink；写失败时落明显的 !CACHE-ERR 标记
    # ============================================================
    if [ "$err" = 1 ]; then
        err_seg='#[fg=red,bold] !ERR '
    else
        err_seg=''
    fi

    tmpfile=$(mktemp "${CACHE}.XXXXXX" 2>/dev/null)
    if [ -z "$tmpfile" ]; then
        # mktemp 失败：直接落错误缓存，让用户看到
        printf '#[fg=red,bold] !MKTEMP-ERR #[default]' > "$CACHE" 2>/dev/null
    else
        if printf '%s#[fg=colour244]│#[fg=green]  CPU %d%% #[fg=colour244]│#[fg=magenta]  MEM %d%% #[fg=colour244]│#[fg=yellow] 󰕮 LOAD %d%% #[fg=colour244]│#[fg=cyan]  %s #[default]' \
                "$err_seg" "$cpu" "$mem" "$load_pct" "$procs" \
                > "$tmpfile" 2>/dev/null \
           && mv "$tmpfile" "$CACHE" 2>/dev/null; then
            :  # 成功
        else
            rm -f "$tmpfile" 2>/dev/null
            printf '#[fg=red,bold] !CACHE-WRITE-ERR #[default]' > "$CACHE" 2>/dev/null
        fi
    fi
) </dev/null >/dev/null 2>&1 &

exit 0
