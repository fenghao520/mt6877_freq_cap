#!/system/bin/sh
# ============================================================================
# 深度睡眠（Deep Sleep）· 复刻自 ynltoto「若晴官调限频 v4.4」
#
# 判定与动作（与原版一致）：
#   熄屏 && 未充电 && 未放音，且持续 grace 秒  → 接管系统 Doze
#     ① 模块白名单里的应用 → 加入系统 Doze 白名单（熄屏后照常工作）
#     ② 其余「用户白名单」应用 → 移出（强迫它们进 Doze）
#     ③ 写入更短的 device_idle_constants（更快进入深度空闲）
#     ④ deviceidle force-idle → 直接强制进入 deep idle
#   亮屏 / 插电 / 放音 → 立即还原（constants 回原值、白名单逐项比对回滚）
#
#   系统自带的 system / system-excidle 白名单（来电、短信、闹钟、IMS…）一律不动，
#   因此通话、短信、闹钟不受影响。
#
#   深睡期间统计「谁在唤醒」，退出时把唤醒排行写进 $DS_WAKE 供 WebUI 展示。
#
# 安全性：接管前先把「原值快照 + 改动清单」落到 $DS_SAVED，
#         守护被杀 / 模块卸载 / 重新开机都会读它做还原，绝不残留系统状态。
# ============================================================================

# 依赖 util.sh 的 CF_DIR（单独 source 本文件时自动补上）
if [ -z "$CF_DIR" ]; then
    _ds_self_dir="$(dirname "$0")"
    . "$_ds_self_dir/util.sh" 2>/dev/null
fi

DS_FILE="$CF_DIR/dsleep.conf"
DS_DIR="$CF_DIR/ds"
DS_ACT="$DS_DIR/active"
DS_SAVED="$DS_DIR/saved.conf"
DS_BASE="$DS_DIR/alarm.base"
DS_WAKE="$DS_DIR/wake.tsv"

DS_GRACE_DEF=20          # 熄屏宽限（秒）
DS_WAKE_TOP=8            # 唤醒排行保留条数
DS_POLL_N=0              # 深睡中「放音」检测的节流计数（见 ds_off_tick）

# 缩短后的 Doze 常量（与若晴 v4.4 同值）：把进入深度空闲的等待从「分钟级」压到「秒级」
DS_CONSTS="inactive_to=10000,sensing_to=0,locating_to=0,motion_inactive_to=0,idle_pending_to=30000,max_idle_pending_to=60000,light_idle_to=5000,light_max_idle_to=15000,idle_to=120000"

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
# 字符串取值（_conf_val 只认数字，这里需要读逗号分隔的包名）
_ds_conf_str() { # 文件 键 默认值
    local f="$1" k="$2" d="$3" v
    [ -f "$f" ] || { printf '%s' "$d"; return; }
    v="$(awk -v key="$k" '{
            line=$0; sub(/[[:space:]]*#.*/,"",line);
            n=split(line,a,"="); if(n<2) next;
            k2=a[1]; gsub(/[[:space:]]/,"",k2); if(k2!=key) next;
            p=index(line,"="); print substr(line,p+1); exit
        }' "$f" 2>/dev/null | tr -d ' \t\r\n')"
    [ -z "$v" ] && v="$d"
    printf '%s' "$v"
}

# 写回配置项（保留文件里的注释与其它行；原子替换）
ds_conf_set() { # 键 值
    local k="$1" v="$2" tmp
    mkdir -p "$CF_DIR" 2>/dev/null
    chmod 0777 "$CF_DIR" 2>/dev/null
    [ -f "$DS_FILE" ] || ds_conf_default
    tmp="$DS_FILE.tmp"
    if grep -qE "^[[:space:]]*$k[[:space:]]*=" "$DS_FILE" 2>/dev/null; then
        awk -v k="$k" -v v="$v" '{
                line=$0; sub(/[[:space:]]*#.*/,"",line); n=split(line,a,"=");
                if(n>=2){ k2=a[1]; gsub(/[[:space:]]/,"",k2); if(k2==k){ print k"="v; next } }
                print
            }' "$DS_FILE" > "$tmp" 2>/dev/null && {
            # 必须 mv（同目录内是原子替换）。用 `cat tmp > 目标` 的话，
            # 目标会先被截断成 0 字节再逐段写入 —— WebUI 恰好在这时读就会拿到空配置，
            # 表现为「页面上的开关/白名单突然全空」。mv 要么看到旧的要么看到新的。
            mv -f "$tmp" "$DS_FILE" 2>/dev/null || cat "$tmp" > "$DS_FILE" 2>/dev/null
        }
    else
        printf '%s=%s\n' "$k" "$v" >> "$DS_FILE"
    fi
    rm -f "$tmp" 2>/dev/null
    chmod 0666 "$DS_FILE" 2>/dev/null
}

ds_conf_default() {
    mkdir -p "$CF_DIR" 2>/dev/null
    cp "$MODDIR/templates/dsleep.conf" "$DS_FILE" 2>/dev/null
    chmod 0666 "$DS_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 配置读写
# ---------------------------------------------------------------------------
ds_enabled() {  # 1 / 0
    local v
    v="$(_ds_conf_str "$DS_FILE" enable 0)"
    case "$v" in 1) echo 1 ;; *) echo 0 ;; esac
}

ds_set_enable() { # 0|1
    case "$1" in
        1) ds_conf_set enable 1 ;;
        *) ds_conf_set enable 0 ;;
    esac
    # 关闭时若正在深睡 → 立即还原
    [ "$1" = "1" ] || { [ -f "$DS_ACT" ] && ds_exit; }
    return 0
}

ds_grace() {
    local v
    v="$(_ds_conf_str "$DS_FILE" grace "$DS_GRACE_DEF")"
    case "$v" in ''|*[!0-9]*) v="$DS_GRACE_DEF" ;; esac
    [ "$v" -lt 5 ] 2>/dev/null && v=5
    echo "$v"
}

# 配置里的白名单（原文，逗号分隔）
ds_white_conf() { _ds_conf_str "$DS_FILE" whitelist ""; }

# 配置白名单 ∩ 已安装 → 真正生效的包名列表
# 用 tr 把逗号换成空格再遍历，避免在 for 里反复改 IFS（mksh 下更稳）
ds_white_effective() {
    local p out=""
    for p in $(ds_white_conf | tr ',' ' '); do
        [ -n "$p" ] || continue
        ds_installed "$p" && out="${out}${out:+,}$p"
    done
    printf '%s' "$out"
}

ds_installed() {
    local p="$1"
    [ -n "$p" ] || return 1
    [ -d "/data/data/$p" ] && return 0
    [ -d "/data/user/0/$p" ] && return 0
    pm path "$p" >/dev/null 2>&1 && return 0
    return 1
}

ds_white_has() { # 包名
    local p="$1" q
    [ -n "$p" ] || return 1
    for q in $(ds_white_conf | tr ',' ' '); do
        [ "$q" = "$p" ] && return 0
    done
    return 1
}

# 加白 / 移出：把整串重排后回写配置
ds_white_add() { # 包名
    local p="$1" list
    [ -n "$p" ] || return 1
    ds_white_has "$p" && return 0
    list="$(ds_white_conf)"
    [ -n "$list" ] && list="$list,$p" || list="$p"
    ds_conf_set whitelist "$list"
    return 0
}

ds_white_del() { # 包名
    local p="$1" q out="" first=1
    [ -n "$p" ] || return 1
    for q in $(ds_white_conf | tr ',' ' '); do
        [ -n "$q" ] || continue
        [ "$q" = "$p" ] && continue
        if [ "$first" = "1" ]; then out="$q"; first=0; else out="$out,$q"; fi
    done
    ds_conf_set whitelist "$out"
    return 0
}

# ---------------------------------------------------------------------------
# 运行环境判定
# ---------------------------------------------------------------------------
ds_charging() { # 1=充电中（含充满）
    # 首选框架自己的判定 —— Doze 用的就是它，语义完全对齐；
    # 兜底才读 sysfs（部分 ROM 没有 cmd deviceidle，或框架状态未及时刷新）
    local v f
    v="$(cmd deviceidle get charging 2>/dev/null | tr -d ' \t\r\n')"
    case "$v" in
        true)  echo 1; return 0 ;;
        false) echo 0; return 0 ;;
    esac
    for f in /sys/class/power_supply/*/status; do
        [ -r "$f" ] || continue
        v="$(cat "$f" 2>/dev/null | tr -d ' \t\r\n')"
        case "$v" in Charging|Full) echo 1; return 0 ;; esac
    done
    echo 0
}

ds_music() { # 1=正在放音（STATE_PLAYING = 3）
    local o
    o="$(dumpsys media_session 2>/dev/null)"
    [ -n "$o" ] || { echo 0; return 0; }
    printf '%s' "$o" | grep -qE 'state=PlaybackState\{state=3[,}]' && { echo 1; return 0; }
    printf '%s' "$o" | sed -n '/Audio playback/,$p' | grep -qE 'state=started' && { echo 1; return 0; }
    echo 0
}

ds_active() { [ -f "$DS_ACT" ] && echo 1 || echo 0; }

# ---------------------------------------------------------------------------
# 系统 Doze 白名单 / 常量
# ---------------------------------------------------------------------------
# 当前系统白名单里的「用户型」包名（只动这一档，system / system-excidle 一律不碰）
ds_sys_white_user() {
    cmd deviceidle whitelist 2>/dev/null | awk -F, '$1=="user" && $2!="" {print $2}'
}

ds_sys_white_has() { # 包名（任意类型）
    cmd deviceidle whitelist 2>/dev/null | awk -F, -v p="$1" '$2==p {print $2; exit}' | grep -q . && return 0
    return 1
}

ds_wl_add()    { cmd deviceidle whitelist "+$1" >/dev/null 2>&1; }
ds_wl_remove() { cmd deviceidle whitelist "-$1" >/dev/null 2>&1; }

ds_consts_get() { settings get global device_idle_constants 2>/dev/null | tr -d ' \t\r\n'; }

# ---------------------------------------------------------------------------
# 唤醒排行：解析 dumpsys alarm 的 Alarm Stats
#   分组行：   1000:android +2s15ms running, 38 wakeups:
#             u0a241:com.google.android.gms +1s317ms running, 41 wakeups:
#   明细行：     +296ms 25 wakes 25 alarms, last -2h16m19s197ms:
#   输出三列：包名<TAB>真正唤醒次数(wakes)<TAB>闹钟触发次数(alarms)
#
#   为什么要分两个口径：现代 Android 的闹钟「批处理」会让大量闹钟在设备本来就清醒时
#   触发，此时只涨 alarms 不涨 wakes。实测本机原生待机 150 秒 wakes 一次都没涨，
#   所以单看 wakes 会永远空榜；两个都要，结算时优先用 wakes、全 0 才回退 alarms。
# ---------------------------------------------------------------------------
ds_alarm_snapshot() {
    dumpsys alarm 2>/dev/null | awk '
        function flush() {
            if (pkg != "" && (wk > 0 || al > 0)) print pkg "\t" wk "\t" al
        }
        /^  [^ ]/ {                       # 分组行（2 空格缩进）
            flush()
            pkg=""; wk=0; al=0
            s=$0; sub(/^  /,"",s)
            i=index(s,":"); if (i < 2) next
            s=substr(s,i+1)
            j=index(s," "); p=(j>0 ? substr(s,1,j-1) : s)
            gsub(/[^A-Za-z0-9_.]/,"",p)
            if (index(p,".") > 0) pkg=p   # 过滤 android / Alarm Stats 这类非包名
            next
        }
        /^    [+-]/ {                     # 明细行（4 空格缩进）
            if (match($0, /[0-9]+ wakes/))  { v=substr($0,RSTART,RLENGTH); sub(/ wakes/,"",v);  wk += v }
            if (match($0, /[0-9]+ alarms/)) { v=substr($0,RSTART,RLENGTH); sub(/ alarms/,"",v); al += v }
            next
        }
        END { flush() }
    '
}

# ---------------------------------------------------------------------------
# 进入 / 退出
# ---------------------------------------------------------------------------
ds_enter() {
    [ "$(ds_active)" = "1" ] && return 0
    mkdir -p "$DS_DIR" 2>/dev/null
    chmod 0777 "$DS_DIR" 2>/dev/null

    local added="" removed="" p white
    white="$(ds_white_effective)"

    # ① 模块白名单：系统里没有 → 加入（记录，退出时移除）
    for p in $(printf '%s' "$white" | tr ',' ' '); do
        [ -n "$p" ] || continue
        if ! ds_sys_white_has "$p"; then
            added="${added}${added:+,}$p"
        fi
    done

    # ② 系统用户白名单里、不在模块白名单的应用：移出（记录，退出时加回）
    for p in $(ds_sys_white_user); do
        [ -n "$p" ] || continue
        case ",$white," in *",$p,"*) continue ;; esac
        ds_installed "$p" || continue
        removed="${removed}${removed:+,}$p"
    done

    # ③ 先把「原值快照 + 改动清单」落盘（必须在动手之前！
    #    这样即使守护被强杀、机器断电，下次开机也能照着它逐项还原）
    {
        echo "ts=$(date +%s)"
        echo "constants=$(ds_consts_get)"
        echo "added=$added"
        echo "removed=$removed"
    } > "$DS_SAVED.tmp" 2>/dev/null
    chmod 0666 "$DS_SAVED.tmp" 2>/dev/null
    mv -f "$DS_SAVED.tmp" "$DS_SAVED" 2>/dev/null
    chmod 0666 "$DS_SAVED" 2>/dev/null
    : > "$DS_ACT" 2>/dev/null
    chmod 0666 "$DS_ACT" 2>/dev/null

    # ④ 唤醒计数基线（用于退出时算「深睡期间唤醒次数」）
    ds_alarm_snapshot > "$DS_BASE.tmp" 2>/dev/null
    mv -f "$DS_BASE.tmp" "$DS_BASE" 2>/dev/null

    # ⑤ 正式接管
    for p in $(echo "$added" | tr ',' ' '); do [ -n "$p" ] && ds_wl_add "$p"; done
    for p in $(echo "$removed" | tr ',' ' '); do [ -n "$p" ] && ds_wl_remove "$p"; done
    settings put global device_idle_constants "$DS_CONSTS" >/dev/null 2>&1
    cmd deviceidle force-idle >/dev/null 2>&1
    DS_POLL_N=0
    return 0
}

# 还原：白名单逐项比对回滚 + constants 回原值 + 解除强制空闲
# 幂等：无论调用多少次、无论中途是否被打断，结果都收敛到「原样」
ds_exit() {
    mkdir -p "$DS_DIR" 2>/dev/null
    local added="" removed="" consts="" p

    if [ -f "$DS_SAVED" ]; then
        added="$(  awk -F= '$1=="added"    {p=index($0,"="); print substr($0,p+1)}' "$DS_SAVED" 2>/dev/null)"
        removed="$(awk -F= '$1=="removed"  {p=index($0,"="); print substr($0,p+1)}' "$DS_SAVED" 2>/dev/null)"
        consts="$( awk -F= '$1=="constants"{p=index($0,"="); print substr($0,p+1)}' "$DS_SAVED" 2>/dev/null | tr -d ' \t\r\n')"
    fi

    # ① 解除强制空闲（即使没有快照也要做，避免残留 force-idle）
    cmd deviceidle unforce >/dev/null 2>&1

    # ② 自己加进去的 → 移除（仅当它现在确实在白名单里）
    for p in $(echo "$added" | tr ',' ' '); do
        [ -n "$p" ] || continue
        ds_sys_white_has "$p" && ds_wl_remove "$p"
    done

    # ③ 自己移出去的 → 加回（仅当它现在确实不在白名单里）
    for p in $(echo "$removed" | tr ',' ' '); do
        [ -n "$p" ] || continue
        ds_sys_white_has "$p" || ds_wl_add "$p"
    done

    # ④ constants 回原值：原本没设过（null）就删掉设置项，绝不留下空串
    #    前提是「确实有快照」。没有快照时就 delete，等于把用户自己设的
    #    device_idle_constants 抹掉 —— ds_cleanup 明确承诺过没有证据不动它，
    #    这里必须保持一致，否则一次误调用就会永久毁掉用户的设置。
    if [ -f "$DS_SAVED" ] && grep -q '^constants=' "$DS_SAVED" 2>/dev/null; then
        case "$consts" in
            ''|null) settings delete global device_idle_constants >/dev/null 2>&1 ;;
            *)       settings put global device_idle_constants "$consts" >/dev/null 2>&1 ;;
        esac
    fi

    # ⑤ 结算唤醒排行（用进入时的基线做差）
    ds_wake_settle

    rm -f "$DS_ACT" "$DS_SAVED" "$DS_BASE" 2>/dev/null
    return 0
}

ds_wake_settle() {
    [ -f "$DS_BASE" ] || return 0
    ds_alarm_snapshot > "$DS_DIR/alarm.now" 2>/dev/null
    [ -s "$DS_DIR/alarm.now" ] || { rm -f "$DS_DIR/alarm.now" 2>/dev/null; return 0; }

    # ① 逐包做差（负差归零：闹钟服务可能在期间重启，计数清零）
    awk -F'\t' '
        NR==FNR { bw[$1]=$2+0; ba[$1]=$3+0; next }
        {
            w=$2-(($1 in bw)?bw[$1]:0); a=$3-(($1 in ba)?ba[$1]:0)
            if (w<0) w=0
            if (a<0) a=0
            if (w>0 || a>0) print $1 "\t" w "\t" a
        }
    ' "$DS_BASE" "$DS_DIR/alarm.now" > "$DS_DIR/diff.tmp" 2>/dev/null

    # ② 口径选择：有任何真实唤醒就用 wakes，否则回退 alarms
    if [ "$(awk -F'\t' '{s+=$2} END{print s+0}' "$DS_DIR/diff.tmp" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        _col=2; _unit=wake
    else
        _col=3; _unit=alarm
    fi
    printf '%s' "$_unit" > "$DS_DIR/wake.unit" 2>/dev/null
    chmod 0666 "$DS_DIR/wake.unit" 2>/dev/null

    # 注意：截断条数要用 shell 变量 $DS_WAKE_TOP —— awk 的 -v 变量只在 awk 里可见，
    # 写成 head -n "$top" 会得到空参数、head 报错并把整条管道的输出吞掉（踩过一次）。
    awk -F'\t' -v c="$_col" '$c+0 > 0 {print $1 "\t" $c}' "$DS_DIR/diff.tmp" 2>/dev/null \
        | sort -t"$(printf '\t')" -k2 -nr | head -n "$DS_WAKE_TOP" > "$DS_WAKE.tmp" 2>/dev/null
    mv -f "$DS_WAKE.tmp" "$DS_WAKE" 2>/dev/null
    chmod 0666 "$DS_WAKE" 2>/dev/null

    rm -f "$DS_DIR/alarm.now" "$DS_DIR/diff.tmp" 2>/dev/null
    return 0
}

# 开机 / 卸载时的残留清理：上次没干净退出（断电、强杀）也能恢复
ds_cleanup() {
    if [ -f "$DS_ACT" ] || [ -f "$DS_SAVED" ]; then
        ds_exit
    else
        # 没有接管痕迹，但仍要解除可能残留的强制空闲。
        # 「不」碰 device_idle_constants —— 用户可能自己设过，没有快照证据就不能动它。
        cmd deviceidle unforce >/dev/null 2>&1
    fi
    rm -f "$DS_ACT" "$DS_SAVED" "$DS_BASE" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 状态输出（给 state.conf / ctl.sh / WebUI 用）
# ---------------------------------------------------------------------------
# 注意：白名单输出「配置原文」，不做「已安装」过滤 —— 该函数每 3 秒被守护调用一次，
#       逐个 pm path 探测太贵；WebUI 自己持有已安装包名表，由前端过滤即可。
ds_white_csv() { ds_white_conf; }

ds_wake_csv() { # pkg:count,pkg:count （最多 DS_WAKE_TOP 条）
    [ -f "$DS_WAKE" ] || return 0
    awk -F'\t' 'NF>=2 {printf "%s%s:%s", (n++?",":""), $1, $2}' "$DS_WAKE" 2>/dev/null
}

# 本次排行用的口径：wake=真正唤醒设备 / alarm=闹钟触发（设备本来清醒时触发）
ds_wake_unit() {
    local u
    u="$(cat "$DS_DIR/wake.unit" 2>/dev/null | tr -d ' \t\r\n')"
    case "$u" in wake) printf 'wake' ;; *) printf 'alarm' ;; esac
}

# ---------------------------------------------------------------------------
# 守护循环钩子
# ---------------------------------------------------------------------------
# 熄屏巡检：**不阻塞**，每轮只判断一次，靠调用方维护的 DS_SINCE 跨轮计时。
#
# 原来是「在 while 里 sleep 到宽限期满」，那样等待期间（最长 grace 秒，默认 20）
# 守护主循环根本转不起来 —— process_cmd 不被调用，这段时间里 WebUI / CLI 下发的
# 命令（切档、恢复不限、停用…）全部要等到宽限结束才被处理，表现就是「点了没反应」。
# 改成状态机后由主循环按 3 秒节奏反复调用，等待期间命令照样及时处理。
ds_off_tick() {
    if [ "$(ds_enabled)" != "1" ]; then
        [ -f "$DS_ACT" ] && ds_exit
        DS_SINCE=""
        return 0
    fi

    if [ "$(ds_active)" = "1" ]; then
        # 已在深睡：前提一旦破坏（亮屏 / 插电 / 放音）立刻还原。
        # 屏幕和充电每轮都查 —— 都很便宜，而且亮屏必须 3 秒内退出。
        if screen_on || [ "$(ds_charging)" = "1" ]; then
            ds_exit
            DS_SINCE=""
            return 0
        fi
        # 「放音」每 5 轮（约 15 秒）才查一次：ds_music 要跑一次完整的
        # dumpsys media_session，3 秒一轮的话光检测就吃掉省下来的电，
        # 与这个功能本身的目的背道而驰。
        DS_POLL_N=$((DS_POLL_N + 1))
        if [ "$DS_POLL_N" -ge 5 ]; then
            DS_POLL_N=0
            if [ "$(ds_music)" = "1" ]; then
                ds_exit
                DS_SINCE=""
            fi
        fi
        return 0
    fi

    [ -n "$DS_SINCE" ] || DS_SINCE="$(date +%s)"
    if screen_on; then DS_SINCE=""; return 0; fi

    local grace now
    grace="$(ds_grace)"
    now="$(date +%s)"
    # 还没到点：直接返回，交给主循环下一轮再判断（期间命令照常处理）
    [ $((now - DS_SINCE)) -lt "$grace" ] 2>/dev/null && return 0

    # 到点了，但前提不满足 → 不进入（下一轮重新计时）
    if screen_on; then DS_SINCE=""; return 0; fi
    if [ "$(ds_charging)" = "1" ]; then DS_SINCE=""; return 0; fi
    if [ "$(ds_music)" = "1" ]; then DS_SINCE=""; return 0; fi

    ds_enter
    DS_SINCE=""
    return 0
}

# 亮屏巡检：只要还在深睡就立即还原
ds_on_tick() {
    [ -f "$DS_ACT" ] || { DS_SINCE=""; return 0; }
    ds_exit
    DS_SINCE=""
    return 0
}
