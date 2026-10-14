#!/system/bin/sh
# 天玑920限频 · 核心工具库
# 控制通道：MTK PPM 原生 /proc/ppm/policy/cluster_{0,1}_max_freq（单位 kHz，-1=不限）
# 注意：该节点写 0 会被内核解释成最低档(650MHz)，只有 -1 表示不限，切勿写 0

MOD_ID=mt6877_freq_cap
# 模块可能位于 modules/（已生效）或 modules_update/（待重启生效），
# /data/adb/modules/$MOD_ID 还可能是只有 module.prop 的占位目录 —— 一律要求含 scripts 才算数
if [ -n "$MODDIR" ] && [ -d "$MODDIR/scripts" ]; then
    :
elif [ -d "/data/adb/modules/$MOD_ID/scripts" ]; then
    MODDIR="/data/adb/modules/$MOD_ID"
elif [ -d "/data/adb/modules_update/$MOD_ID/scripts" ]; then
    MODDIR="/data/adb/modules_update/$MOD_ID"
elif [ -n "$MODPATH" ] && [ -d "$MODPATH/scripts" ]; then
    MODDIR="$MODPATH"
else
    MODDIR="$(dirname "$0")/.."
fi
CONFDIR="$MODDIR/config"
PRESETDIR="$MODDIR/presets"
CPUFREQ_ROOT=/sys/devices/system/cpu/cpufreq
PPM_DIR=/proc/ppm/policy
CF_DIR=/storage/emulated/0/Android/mt6877_freq_cap
CF_FILE="$CF_DIR/custom_freq.conf"
TIER_FILE="$CF_DIR/tier_freq.conf"
MODE_FILE="$CF_DIR/mode.conf"
CMD_FILE="$CF_DIR/cmd"
DISABLE_FILE="$CF_DIR/disable"
STATE_FILE="$CF_DIR/state.conf"
DAEMON_PID_FILE="$CF_DIR/daemon.pid"
DAEMON_SCRIPT="$MODDIR/scripts/daemon.sh"
DAEMON_MARK=mtfcap-daemon

export PATH="${PATH}:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin"

# ---------- SoC ----------
_soc_platform_get() { getprop ro.board.platform | tr '[A-Z]' '[a-z]'; }
_soc_model_get()   { getprop ro.soc.model | tr '[A-Z]' '[a-z]'; }

# 只保留 [A-Za-z0-9_]，且只取第一行。
# 为什么必须过滤：soc 会被拼进 "$PRESETDIR/$soc.conf" 并被 get_tier 当脚本 source。
# 若放任任意字符（config/soc.override 里写 "../.." 之类），就能让模块去执行
# 预设目录之外的任意文件 —— 那是以 root 跑任意代码。一律收敛到白名单字符集。
_soc_sanitize() {
    local s
    s="$(head -n1 "$1" 2>/dev/null | tr -cd 'A-Za-z0-9_')"
    [ -n "$s" ] && printf '%s' "$s"
}

detect_soc() {
    local s
    if [ -f "$CONFDIR/soc.override" ]; then
        s="$(_soc_sanitize "$CONFDIR/soc.override")"
        [ -n "$s" ] && { echo "$s"; return; }
    fi
    local p m
    p="$(_soc_platform_get)"; m="$(_soc_model_get)"
    case "$p" in
        mt6877|mt6877t|mt6877v|mt6878|mt6879) echo MT6877 ;;
        *) case "$m" in mt6877*|mt6878|mt6879) echo MT6877 ;; esac ;;
    esac
}

# ---------- 集群 ↔ policy 映射 ----------
# 本机：cluster0 = policy0(A55小核 0-5) / cluster1 = policy6(A78大核 6-7)
policy_of_cluster() {
    case "$1" in 0) echo "$CPUFREQ_ROOT/policy0" ;; 1) echo "$CPUFREQ_ROOT/policy6" ;; esac
}
cpu_min() { cat "$(policy_of_cluster "$1")/cpuinfo_min_freq" 2>/dev/null; }
cpu_max() { cat "$(policy_of_cluster "$1")/cpuinfo_max_freq" 2>/dev/null; }
cpu_cur() { cat "$(policy_of_cluster "$1")/cpuinfo_cur_freq" 2>/dev/null; }

ppm_node() { echo "$PPM_DIR/cluster_$1_max_freq"; }
ppm_val()  { sed -n 's/.*= *//p' "$(ppm_node "$1")" 2>/dev/null | tr -d ' \t\r\n'; }

# PPM 节点读回的不是 kHz，而是「该簇 OPP 表的降序索引」（实测所得，见下表）。
# 写进去用 kHz，读出来是索引；-1 仍表示不限。这里把它换算成 kHz 便于显示。
#   A55 索引 0..15 → 2000 1903 1800 1703 1600 1503 1407 1310 1260 1150 1053 980 900 740 650 500 (MHz)
#   A78 索引 0..15 → 2500 2400 2275 2150 2000 1900 1800 1660 1540 1430 1300 1140 1040 910 740 650 (MHz)
ppm_opp_list() {
    case "$1" in
        0) echo "2000000 1903000 1800000 1703000 1600000 1503000 1407000 1310000 1260000 1150000 1053000 980000 900000 740000 650000 500000" ;;
        1) echo "2500000 2400000 2275000 2150000 2000000 1900000 1800000 1660000 1540000 1430000 1300000 1140000 1040000 910000 740000 650000" ;;
    esac
}
# ppm_khz <cluster> [索引] → 当前上限的 kHz；不限返回 -1；读不到返回空
ppm_khz() {
    local c="$1" idx="${2:-}"
    [ -n "$idx" ] || idx="$(ppm_val "$c")"
    case "$idx" in
        '') echo "" ;;
        -*|*[!0-9]*) echo "$idx" ;;
        # 索引从 0 开始，awk 字段从 1 开始 → 取第 (idx+1) 个
        *) ppm_opp_list "$c" | awk -v i="$idx" '{print $(i+1)}' | head -n1 ;;
    esac
}

# ---------- 核心安全写入 ----------
# 严格整数校验：可选一个前导 '-'，其后必须全是数字且至少一位。
# 不能用 `case "$v" in ''|*[!0-9-]*)` 那种写法 —— 它会把 "-"、"1-2"、 "--"
# 这类残缺串也判成合法数字，然后原样写进 /proc 节点。
_is_int() {
    local v="${1:-}"
    case "$v" in -*) v="${v#-}" ;; esac
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# ppm_set <cluster 0|1> <khz|0|-1>
# 0 / 负数 / 非数字 一律解释为「不限」(-1)，绝不允许落到最低档
# 超范围值自动钳制到 [cpuinfo_min_freq, cpuinfo_max_freq]
# 内核会再把 kHz 对齐到真实 OPP 档位，因此不可能写入非法频点
ppm_set() {
    local c="$1" val="$2" node mn mx
    node="$(ppm_node "$c")"
    [ -e "$node" ] || return 1
    _is_int "$val" || val=-1
    [ "$val" -le 0 ] 2>/dev/null && val=-1
    if [ "$val" != "-1" ]; then
        mn="$(cpu_min "$c")"; mx="$(cpu_max "$c")"
        [ -n "$mn" ] && [ "$val" -lt "$mn" ] && val="$mn"
        [ -n "$mx" ] && [ "$val" -gt "$mx" ] && val="$mx"
    fi
    # 写入失败必须返回非 0 —— 调用方靠返回值决定「下一轮要不要重试」。
    # 原来这里无条件 return 0，于是偶发的一次写失败会被当成成功记进签名，
    # 而守护的「值没变就不重写」优化会让它**永远不再补写**，表现为改了却不生效。
    echo "$val" > "$node" 2>/dev/null || return 1
    return 0
}

ppm_release() { local c; for c in 0 1; do echo -1 > "$(ppm_node "$c")" 2>/dev/null; done; }

# 把 kHz 对齐到真实可选频点（仅用于显示/预估，内核自身也会对齐）
clamp_freq() {
    local c="$1" target="$2" avail f best=""
    avail="$(cat "$(policy_of_cluster "$c")/scaling_available_frequencies" 2>/dev/null)"
    [ -z "$avail" ] && { echo "$target"; return; }
    for f in $avail; do
        if [ "$f" -le "$target" ]; then
            [ -z "$best" ] || [ "$f" -gt "$best" ] && best="$f"
        fi
    done
    [ -z "$best" ] && best="$(echo $avail | tr ' ' '\n' | sort -n | head -n1)"
    echo "$best"
}

# ---------- 配置读取 ----------
ensure_cf() {
    mkdir -p "$CF_DIR" 2>/dev/null
    chmod 0777 "$CF_DIR" 2>/dev/null
    [ -f "$MODE_FILE" ]  || { cp "$MODDIR/templates/mode.conf" "$MODE_FILE" 2>/dev/null; chmod 0666 "$MODE_FILE"; }
    [ -f "$CF_FILE" ]    || { cp "$MODDIR/templates/custom_freq.conf" "$CF_FILE" 2>/dev/null; chmod 0666 "$CF_FILE"; }
    [ -f "$CF_DIR/dsleep.conf" ] || { cp "$MODDIR/templates/dsleep.conf" "$CF_DIR/dsleep.conf" 2>/dev/null; chmod 0666 "$CF_DIR/dsleep.conf"; }
    mkdir -p "$CF_DIR/ds" 2>/dev/null
    chmod 0777 "$CF_DIR/ds" 2>/dev/null
    cp "$MODDIR/templates/README.txt" "$CF_DIR/使用说明.txt" 2>/dev/null
    chmod 0644 "$CF_DIR/使用说明.txt" 2>/dev/null
    [ -f "$CMD_FILE" ] || { : > "$CMD_FILE" 2>/dev/null; chmod 0666 "$CMD_FILE"; }
}

_conf_val() { # 文件 键 默认值
    local f="$1" k="$2" d="$3" v
    [ -f "$f" ] || { echo "$d"; return; }
    v="$(awk -F= -v key="$k" '{
            line=$0; sub(/[[:space:]]*#.*/,"",line);
            n=split(line,a,"="); if(n<2) next;
            gsub(/[[:space:]]/,"",a[1]); if(a[1]==key){print a[2]; exit}
        }' "$f" 2>/dev/null | tr -d ' \t\r')"
    _is_int "$v" || v="$d"
    echo "$v"
}

get_mode() { # daily|game
    local slot="$1" f="$2"
    [ -n "$f" ] || f="$MODE_FILE"
    [ -f "$f" ] || f="$CONFDIR/mode.conf"
    [ -f "$f" ] || { [ "$slot" = game ] && echo fast || echo balance; return; }
    local v
    if [ "$slot" = game ]; then
        v="$(awk -F= '/^[[:space:]]*mode_game[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$f")"
    else
        v="$(awk -F= '/^[[:space:]]*mode_daily[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$f")"
    fi
    case "$v" in powersave|balance|performance|fast) echo "$v" ;;
        *) [ "$slot" = game ] && echo fast || echo balance ;; esac
}

# 档位频率：自定义(ENABLE=1) > tier_freq.conf 覆盖 > 内置预设表 > 硬件最大
# 用法：get_tier <模式> <场景daily|game> <簇0|1> [pinned]
#   pinned=1 表示该模式来自「开机提速」，此时跳过自定义频率
#            （开机提速的意图就是给足性能，不该被自定义上限压住）
# 返回：正数 kHz；或 0 —— 0 在 ppm_set 里被解释为「不限」
get_tier() {
    local mode="$1" scene="$2" c="$3" pinned="$4" soc CL key val
    soc="$(detect_soc)"; [ -z "$soc" ] && soc=MT6877
    [ "$c" = 1 ] && CL=BIG || CL=LITTLE

    # 1) 用户自定义频率。键名 <LITTLE|BIG>_<DAILY|GAME>（全局自定义，与档位无关）
    if [ "$pinned" != "1" ] && [ "$(_conf_val "$CF_FILE" ENABLE 0)" = "1" ]; then
        key="${CL}_$(echo "$scene" | tr 'a-z' 'A-Z')"
        val="$(_conf_val "$CF_FILE" "$key" "")"
        if [ -n "$val" ]; then
            case "$val" in
                0|-*|*[!0-9]*) echo 0 ;;   # 0 / 负数 / 非法值 一律 = 不限
                *)              echo "$val" ;;
            esac
            return 0
        fi
    fi

    # 2) 用户自定义档位表 tier_freq.conf，键名 <MODE>_<LITTLE|BIG>_<SCENE>
    #    比较时统一转大写：兼容早期 WebUI 写成小写键名的文件
    key="$(echo "${mode}_${CL}_${scene}" | tr 'a-z' 'A-Z')"
    val="$(awk -F= -v k="$key" '{
            line=$0; sub(/[[:space:]]*#.*/,"",line); n=split(line,a,"=");
            if(n<2) next; gsub(/[[:space:]]/,"",a[1]); if(toupper(a[1])==k){print a[2]; exit}
        }' "$TIER_FILE" 2>/dev/null | tr -d ' \t\r')"
    case "$val" in ''|*[!0-9]*) val=0 ;; esac
    if [ "$val" = "0" ]; then
        # 3) 内置预设表
        #    用 awk 解析，而不是 `source` + `eval`：
        #    source 会把「由 soc 拼出来的路径」当脚本执行，等于给任意代码开了口子；
        #    而且它还会把预设文件里的变量带进当前 shell 污染命名空间。
        val="$(awk -F= -v k="$key" '{
                line=$0; sub(/[[:space:]]*#.*/,"",line); n=split(line,a,"=");
                if(n<2) next; gsub(/[[:space:]]/,"",a[1]); if(toupper(a[1])==k){print a[2]; exit}
            }' "$PRESETDIR/$soc.conf" 2>/dev/null | tr -d ' \t\r')"
        case "$val" in ''|*[!0-9]*) val="$(cpu_max "$c")" ;; esac
    fi
    echo "$val"
}

is_game() {
    local pkg="$1"
    [ -n "$pkg" ] || return 1
    # 必须 -F（按字面匹配）：包名里的 "." 在正则里是「任意字符」，
    # 用 grep -x 的话 com.foo.bar 会连 comXfooXbar 一起命中。
    grep -Fxq "$pkg" "$CONFDIR/games.list" 2>/dev/null && return 0
    grep -Fxq "$pkg" "$CF_DIR/mygames.list" 2>/dev/null && return 0
    return 1
}

# ---------- 系统状态 ----------
screen_on() {
    local b
    for b in /sys/class/leds/lcd-backlight/brightness /sys/class/backlight/panel0-backlight/brightness /sys/class/backlight/backlight/brightness; do
        [ -r "$b" ] || continue
        [ "$(cat "$b" 2>/dev/null | tr -d ' \t\r\n')" != "0" ] && return 0
    done
    # 回退：电源状态
    dumpsys power 2>/dev/null | grep -q "mWakefulness=Awake" && return 0
    return 1
}

foreground_pkg() {
    local w
    w="$(dumpsys window 2>/dev/null)"
    printf '%s\n' "$w" | sed -n 's/.*mCurrentFocus=Window{[^ ]* u0 \([^/]*\)\/.*/\1/p' | head -n1
}

# ---------- 守护进程管理 ----------
# 以 PID 文件优先，但**始终**再做一次全量扫描：
#   · pidfile 里的 PID 作为首选目标（最精确）
#   · 扫描 /proc/*/cmdline 里命令行含 scripts/daemon.sh 的进程（去重、排除自身与父进程）
# 只认 pidfile 会漏掉「上一轮重启残留的重复守护」，两个守护同时写 PPM 会互相打架，
# 因此这里每次都把重复项一起收回。
daemon_pids() {
    local p f pid out="" self="${SELF_PID:-$$}"
    if [ -f "$DAEMON_PID_FILE" ]; then
        p="$(tr -d ' \t\r\n' < "$DAEMON_PID_FILE" 2>/dev/null)"
        case "$p" in ''|*[!0-9]*) p="" ;; esac
        if [ -n "$p" ] && [ -r "/proc/$p/cmdline" ]; then
            tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "scripts/daemon\.sh" && out="$p "
        fi
    fi
    for f in /proc/[0-9]*/cmdline; do
        [ -r "$f" ] || continue
        pid="${f#/proc/}"; pid="${pid%/cmdline}"
        [ "$pid" = "$self" ] && continue
        [ "$pid" = "$PPID" ] && continue
        case " $out " in *" $pid "*) continue ;; esac
        tr '\0' ' ' < "$f" 2>/dev/null | grep -q "scripts/daemon\.sh" || continue
        out="$out$pid "
    done
    printf '%s' "$out"
}

kill_daemon() {
    local p f cpid line rest st r2 ppid
    for p in $(daemon_pids); do
        # 先收掉守护拉起的子进程（dumpsys 等），再杀守护本体
        for f in /proc/[0-9]*/stat; do
            [ -r "$f" ] || continue
            cpid="${f#/proc/}"; cpid="${cpid%/stat}"
            case "$cpid" in ''|*[!0-9]*) continue ;; esac
            read -r line < "$f" 2>/dev/null || continue
            # /proc/PID/stat 的第 2 个字段是 "(comm)" —— 进程名里可能含空格
            # （Android 上确实存在）。若直接按空格切字段，comm 一有空格后面全部错位，
            # ppid 会取到别的值，于是「按 ppid 收子进程」可能杀到无关进程。
            # 先剥掉 "pid (comm) " 这一段，剩下的开头就是 "state ppid ..."。
            rest="${line#*) }"
            [ "$rest" != "$line" ] || continue
            st="${rest%% *}"                 # state
            r2="${rest#* }"                  # 去掉 state
            ppid="${r2%% *}"                 # ppid
            case "$ppid" in ''|*[!0-9]*) continue ;; esac
            [ "$ppid" = "$p" ] || continue
            kill "$cpid" 2>/dev/null
        done
        kill "$p" 2>/dev/null
    done
    sleep 1
    for p in $(daemon_pids); do kill -9 "$p" 2>/dev/null; done
    rm -f "$DAEMON_PID_FILE" 2>/dev/null
}

start_daemon() {
    local bin="$1"; shift
    [ -x "$bin" ] || return 1
    setsid "$bin" "$@" >/dev/null 2>&1 </dev/null &
    sleep 1
    [ -n "$(daemon_pids)" ] && return 0
    setsid "$bin" "$@" >/dev/null 2>&1 </dev/null &
    sleep 1
    [ -n "$(daemon_pids)" ]
}

# ---------- 按键 ----------
key_press() {
    local start now ev key=""
    start=$(date +%s)
    while true; do
        now=$(date +%s)
        [ $((now - start)) -ge "$1" ] && { echo timeout; return; }
        ev="$(timeout 0.1 getevent -lqc1 2>/dev/null)"
        case "$ev" in
            *VOLUMEUP*)   case "$ev" in *DOWN*) key=up;   break ;; esac ;;
            *VOLUMEDOWN*) case "$ev" in *DOWN*) key=down; break ;; esac ;;
        esac
    done
    while ev="$(timeout 0.15 getevent -l 2>/dev/null)"; do [ -n "$ev" ] || break; done
    echo "$key"
}

_mcn() {
    case "$1" in
        powersave)   echo 省电 ;;
        balance)     echo 均衡 ;;
        performance) echo 性能 ;;
        fast)        echo 极速 ;;
        *)           echo "$1" ;;
    esac
}
