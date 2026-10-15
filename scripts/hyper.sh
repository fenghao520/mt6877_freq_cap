#!/system/bin/sh
# ============================================================================
# 实验功能 · 全部拉满（仅供跑分）
#
#   ① CPU 两簇上限 → 硬件最大；并尝试把下限也贴上去
#   ② GPU  → 锁定到 OPP 表最高档
#   ③ DDR  → 锁定到最高档
#
# ============================================================================
# 本机（Redmi Note 11 Pro+ / MT6877 / 内核 4.14.357）**实测确认**的三组语义：
#
#   ① CPU 下限   /proc/ppm/policy/cluster_{0,1}_min_freq
#        写 kHz（内核对齐到真实 OPP）；**回读是「升序索引」**（0 = 最低频，
#        与 max 节点的降序索引正好相反，符合语义）；释放值 = -1（写 0 也等于 -1）
#        ⚠️ 因为回读是索引、而写入要 kHz，**索引不能直接写回去** ——
#          所以 ppm 模式的还原统一写 -1（该节点的默认值），不照抄快照。
#
#   ② GPU 固定   /proc/gpufreq/gpufreq_opp_freq
#        写 kHz；回读是状态文本（`[GPU-DVFS] fixed OPP is enabled/disabled`）；
#        释放值 = 0；最高档从 gpufreq_opp_dump 里取（本机 = 950000 kHz，共 38 档）
#
#   ③ DDR 强制   /sys/devices/platform/<addr>.dvfsrc/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp
#        写 OPP 索引（0 = 最高档）；**只写不可读**（cat 为空）；
#        释放值 = 32（0x20，dvfsrc_dump 里 PM_QOS_FORCE_OPP 的「未强制」哨兵值）
#        注意：它会连 VCORE 电压一起拉满；只管 DDR 可用同目录的 dvfsrc_req_ddr_opp
#
#   所有节点都是**内核运行时状态 —— 重启一定清零**，这是最后一道兜底。
#   整套按防御式写：节点多候选探测、找不到就跳过、失败项如实上报，不假装成功。
# ============================================================================

if [ -z "$CF_DIR" ]; then
    _hy_self_dir="$(dirname "$0")"
    . "$_hy_self_dir/util.sh" 2>/dev/null
fi

HY_FILE="$CF_DIR/hyper.conf"
HY_SAVED="$CF_DIR/hyper.saved"   # 原值快照
HY_MARK="$CF_DIR/hyper.on"       # 存在 = 当前处于满血状态

# 探测结果（由 hy_detect 填充）
HY_GPU_NODE=""
HY_GPU_MODE=""      # index = 写 OPP 档位索引；freq = 写频率
HY_DDR_NODE=""
HY_DDR_DIR=""       # dvfsrc 目录（读 num_opps / dump 用）
# CPU 下限节点：形如 "0:ppm:/proc/ppm/policy/cluster_0_min_freq" 的空格分隔列表
#   簇号 : 类型(ppm|scaling) : 路径
#   两种类型的**释放方式不同**：ppm 写 -1；scaling 写回原 kHz
HY_CPU_NODES=""

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
_hy_str() { # 文件 键 默认值
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

hy_enabled() { case "$(_hy_str "$HY_FILE" enable 0)" in 1) echo 1 ;; *) echo 0 ;; esac; }

hy_conf_set() { # 值
    local v="$1" tmp
    mkdir -p "$CF_DIR" 2>/dev/null
    chmod 0777 "$CF_DIR" 2>/dev/null
    [ -f "$HY_FILE" ] || hy_conf_default
    tmp="$HY_FILE.tmp"
    if grep -qE "^[[:space:]]*enable[[:space:]]*=" "$HY_FILE" 2>/dev/null; then
        awk -v v="$v" '{
                line=$0; sub(/[[:space:]]*#.*/,"",line); n=split(line,a,"=");
                if(n>=2){ k2=a[1]; gsub(/[[:space:]]/,"",k2); if(k2=="enable"){ print "enable="v; next } }
                print
            }' "$HY_FILE" > "$tmp" 2>/dev/null && {
            mv -f "$tmp" "$HY_FILE" 2>/dev/null || cat "$tmp" > "$HY_FILE" 2>/dev/null
        }
    else
        printf 'enable=%s\n' "$v" >> "$HY_FILE"
    fi
    rm -f "$tmp" 2>/dev/null
    chmod 0666 "$HY_FILE" 2>/dev/null
}

hy_conf_default() {
    mkdir -p "$CF_DIR" 2>/dev/null
    cp "$MODDIR/templates/hyper.conf" "$HY_FILE" 2>/dev/null
    chmod 0666 "$HY_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 能力探测
# ---------------------------------------------------------------------------
# GPU：优先 v2（按 OPP 档位索引锁），退回 v1（按频率锁）
hy_detect_gpu() {
    local p
    for p in /proc/gpufreqv2/fix_target_opp_index /proc/gpufreq/fix_target_opp_index; do
        if [ -e "$p" ]; then HY_GPU_NODE="$p"; HY_GPU_MODE=index; return 0; fi
    done
    for p in /proc/gpufreq/gpufreq_opp_freq /proc/gpufreqv2/gpufreq_opp_freq; do
        if [ -e "$p" ]; then HY_GPU_NODE="$p"; HY_GPU_MODE=freq; return 0; fi
    done
    HY_GPU_NODE=""; HY_GPU_MODE=""
    return 1
}

# DDR：内核 4.x 带平台地址前缀；5.x 是 /sys/kernel/helio-dvfsrc/
hy_detect_ddr() {
    local p q
    HY_DDR_NODE=""; HY_DDR_DIR=""
    # 本机实测是 /sys/devices/platform/10012000.dvfsrc/helio-dvfsrc/（4.x 带平台地址）；
    # 5.x 是 /sys/kernel/helio-dvfsrc/，两条都留着。
    for p in /sys/devices/platform/*.dvfsrc/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp \
             /sys/devices/platform/*dvfsrc*/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp \
             /sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp; do
        for q in $p; do
            [ -e "$q" ] && { HY_DDR_NODE="$q"; HY_DDR_DIR="$(dirname "$q")"; return 0; }
        done
    done
    return 1
}

# CPU 下限：优先 PPM 自己的 min 节点（因为 PPM 会覆盖 cpufreq 子系统），
# 没有才退回 scaling_min_freq。本机实测两条都有，走 PPM。
hy_detect_cpu() {
    local c d out=""
    for c in 0 1; do
        d="/proc/ppm/policy/cluster_${c}_min_freq"
        [ -e "$d" ] && out="$out ${c}:ppm:${d}"
    done
    [ -n "$out" ] || {
        for c in 0 1; do
            d="$(policy_of_cluster "$c" 2>/dev/null)/scaling_min_freq"
            [ -e "$d" ] && out="$out ${c}:scaling:${d}"
        done
    }
    HY_CPU_NODES="$out"
    [ -n "$out" ]
}

# 从 "簇:类型:路径" 里取字段
_hy_field() { # 条目 序号(1..3)
    local e="$1" n="$2" rest="$1" i=1
    while [ "$i" -lt "$n" ]; do rest="${rest#*:}"; i=$((i + 1)); done
    printf '%s' "${rest%%:*}"
}

# 探测函数**必须永远返回 0**：它是「查一遍」，不是「判断能不能用」。
# 里面三个子函数在找不到节点时会返回 1（作为它们自己的语义），
# 但如果让 hy_detect 把这个 1 传出去，任何 `set -e` 或 `&&` 链里调用它的脚本
# 都会在本机没有这些节点时直接退出 —— 静默失败，很难查。
hy_detect() {
    hy_detect_gpu >/dev/null 2>&1 || true
    hy_detect_ddr >/dev/null 2>&1 || true
    hy_detect_cpu >/dev/null 2>&1 || true
    return 0
}

# 能力位（给 state.conf / UI 用）：1=可用 0=本机没有
hy_cap() { # gpu|ddr|cpu
    hy_detect >/dev/null 2>&1
    case "$1" in
        gpu) [ -n "$HY_GPU_NODE" ] && echo 1 || echo 0 ;;
        ddr) [ -n "$HY_DDR_NODE" ] && echo 1 || echo 0 ;;
        cpu) [ -n "$HY_CPU_NODES" ] && echo 1 || echo 0 ;;
    esac
}

_hy_w() { # 路径 值
    [ -n "$1" ] && [ -e "$1" ] || return 1
    echo "$2" > "$1" 2>/dev/null || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 快照
# ---------------------------------------------------------------------------
hy_snapshot() {
    [ -f "$HY_SAVED" ] && return 0
    hy_detect >/dev/null 2>&1
    mkdir -p "$CF_DIR" 2>/dev/null
    {
        echo "ts=$(date +%s)"
        echo "gpu_node=$HY_GPU_NODE"
        echo "gpu_mode=$HY_GPU_MODE"
        echo "gpu_orig=$(cat "$HY_GPU_NODE" 2>/dev/null | tr -d ' \t\r\n')"
        echo "ddr_node=$HY_DDR_NODE"
        echo "ddr_orig=$(cat "$HY_DDR_NODE" 2>/dev/null | tr -d ' \t\r\n')"
        # CPU 下限原值：逐条记「簇号 / 类型 / 路径 / 原值」
        # ⚠️ ppm 节点回读的是**带文字的升序索引**（如 "cluster 0 min_freq_limit = -1"），
        #    而写入要的是 kHz —— 所以这个原值**不能直接写回去**，只留作展示；
        #    还原时 ppm 统一写 -1（见 hy_exit）。scaling 节点回读就是 kHz，可以照抄。
        local e c mode p v
        for e in $HY_CPU_NODES; do
            c="$(_hy_field "$e" 1)"; mode="$(_hy_field "$e" 2)"; p="$(_hy_field "$e" 3)"
            case "$mode" in
                ppm) v="$(cat "$p" 2>/dev/null | sed -n 's/.*= *//p' | tr -d ' \t\r\n')" ;;
                *)   v="$(cat "$p" 2>/dev/null | tr -d ' \t\r\n')" ;;
            esac
            echo "cpu${c}_mode=$mode"
            echo "cpu${c}_node=$p"
            echo "cpu${c}_orig=$v"
        done
    } > "$HY_SAVED.tmp" 2>/dev/null
    chmod 0666 "$HY_SAVED.tmp" 2>/dev/null
    mv -f "$HY_SAVED.tmp" "$HY_SAVED" 2>/dev/null
    chmod 0666 "$HY_SAVED" 2>/dev/null
    return 0
}

_hy_saved() { # 键
    [ -f "$HY_SAVED" ] || return 1
    sed -n "s/^$1=//p" "$HY_SAVED" 2>/dev/null | head -n1
}

# ---------------------------------------------------------------------------
# 进入 / 退出
# ---------------------------------------------------------------------------
# 真正的写入动作，幂等。返回「未完成项」列表（可能为空）。
# 写成独立函数是为了让自愈复查能直接重用它 —— 详见下面的 hy_verify_*。
hy_apply() {
    hy_detect >/dev/null 2>&1
    local fails="" e c p gmax

    # ① CPU：上限拉到硬件最大；下限也贴上去
    ppm_set 0 "$(cpu_max 0)" || fails="${fails}cpu_max0 "
    ppm_set 1 "$(cpu_max 1)" || fails="${fails}cpu_max1 "
    # 每簇用自己的硬件最大：cluster0 = 2000MHz、cluster1 = 2500MHz。
    # （第一版这里两簇都写 cpu_max 0，等于把大核下限设成 2000 —— 实机测试时才发现的错）
    for e in $HY_CPU_NODES; do
        c="$(_hy_field "$e" 1)"; p="$(_hy_field "$e" 3)"
        _hy_w "$p" "$(cpu_max "$c")" || fails="${fails}cpu_min${c} "
    done

    # ② GPU：锁到 OPP 最高档
    if [ -n "$HY_GPU_NODE" ]; then
        if [ "$HY_GPU_MODE" = "freq" ]; then
            # v1 是按频率锁，最高档要从 OPP 表里读；读不到就不勉强
            gmax="$(sed -n 's/.*[Ff]req[^0-9]*\([0-9]\{6,\}\).*/\1/p' /proc/gpufreq/gpufreq_opp_dump 2>/dev/null | sort -n | tail -n1)"
            [ -n "$gmax" ] && _hy_w "$HY_GPU_NODE" "$gmax" || fails="${fails}gpu "
        else
            _hy_w "$HY_GPU_NODE" 0 || fails="${fails}gpu "
        fi
    else
        fails="${fails}gpu_na "
    fi

    # ③ DDR：锁最高档
    if [ -n "$HY_DDR_NODE" ]; then
        _hy_w "$HY_DDR_NODE" 0 || fails="${fails}ddr "
    else
        fails="${fails}ddr_na "
    fi

    printf '%s' "$fails"
    return 0
}

hy_enter() {
    [ -f "$HY_MARK" ] && return 0
    hy_snapshot
    local fails
    fails="$(hy_apply)"
    printf '%s' "$fails" > "$HY_MARK.tmp" 2>/dev/null
    mv -f "$HY_MARK.tmp" "$HY_MARK" 2>/dev/null
    chmod 0666 "$HY_MARK" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 自愈复查
#
# 为什么需要：满血状态虽然没被系统主动重置（实测 60 秒稳定），但**任何一次外部写入
# 都会把它冲掉** —— 比如别处调一次 ppm_release、或某次写入半途失败。
# 而「只在开启那一刻应用一次」的写法，一旦被冲掉就再也回不来，
# 用户只会觉得「这个开关是坏的」。所以每轮复查 + 就地重写。
#
# 分两级：CPU 只读 4 个 /proc 节点，很便宜 → 每轮都查；
#         GPU/DDR 要读 gpufreq 状态和整个 dvfsrc_dump，较贵 → 每 5 轮查一次。
# ---------------------------------------------------------------------------

# CPU 是否仍处于满血
hy_verify_cpu() {
    local e c mode p v
    # 上限必须是 0（该节点读回的是降序索引，0 = 最高档）
    [ "$(ppm_val 0)" = "0" ] || return 1
    [ "$(ppm_val 1)" = "0" ] || return 1
    for e in $HY_CPU_NODES; do
        c="$(_hy_field "$e" 1)"; mode="$(_hy_field "$e" 2)"; p="$(_hy_field "$e" 3)"
        case "$mode" in
            ppm) v="$(cat "$p" 2>/dev/null | sed -n 's/.*= *//p' | tr -d ' \t\r\n')"
                 # -1 或空 = 下限被清掉了
                 case "$v" in ''|-1) return 1 ;; esac ;;
            *)   v="$(cat "$p" 2>/dev/null | tr -d ' \t\r\n')"
                 [ "$v" = "$(cpu_max "$c")" ] || return 1 ;;
        esac
    done
    return 0
}

# GPU / DDR 是否仍被锁着
hy_verify_io() {
    [ -n "$HY_GPU_NODE" ] && ! grep -q 'is enabled' "$HY_GPU_NODE" 2>/dev/null && return 1
    [ -n "$HY_DDR_NODE" ] || return 0
    local f
    f="$(cat "$HY_DDR_DIR/dvfsrc_dump" 2>/dev/null \
         | sed -n 's/.*PM_QOS_FORCE_OPP *: *//p' | tr -d ' \t\r\n')"
    # 0x20（或读不到）＝ 已不处于强制状态
    case "$f" in ''|*0x20*) return 1 ;; esac
    return 0
}

# 就地重写（不复位标记、不重做快照）。返回「本次修的项」列表，供状态展示。
hy_reapply() {
    local out=""
    hy_verify_cpu || out="${out}cpu "
    hy_verify_io  || out="${out}io "
    [ -n "$out" ] || return 0
    hy_apply >/dev/null 2>&1
    printf '%s' "$out"
    return 0
}

# 自愈计数（由守护维护并写进 state.conf，让用户看得见「自动修过几次」）
hy_fixes() { printf '%s' "${HY_FIXES:-0}"; }

# DDR 解除强制。
# ⚠️ 释放值**不是 -1**：本机实测 0x20(=32) 才是 dvfsrc_dump 里「未强制」的哨兵值；
#    写 30（num_opps）会被当成合法档位（dump 回显 0x1e），反而没解除。
#    写完读 dump 校验一次，没解除再补一刀大值。
_hy_ddr_release() {
    [ -n "$HY_DDR_NODE" ] || return 0
    _hy_w "$HY_DDR_NODE" 32
    local f
    f="$(cat "$HY_DDR_DIR/dvfsrc_dump" 2>/dev/null \
         | sed -n 's/.*PM_QOS_FORCE_OPP *: *//p' | tr -d ' \t\r\n')"
    case "$f" in
        ''|*0x20*) return 0 ;;   # 已是 0x20，或读不到 dump（没证据就当作已解除）
    esac
    _hy_w "$HY_DDR_NODE" 255
    return 0
}

# 还原：逐项交还控制权
hy_exit() {
    hy_detect >/dev/null 2>&1

    # ① CPU 下限
    #    ppm 节点：统一写 -1（回读是索引、写入要 kHz，原值不能照抄回写）
    #    scaling 节点：写回快照里的 kHz
    local e c mode p orig
    for e in $HY_CPU_NODES; do
        c="$(_hy_field "$e" 1)"; mode="$(_hy_field "$e" 2)"; p="$(_hy_field "$e" 3)"
        orig="$(_hy_saved "cpu${c}_orig")"
        if [ "$mode" = "ppm" ]; then
            _hy_w "$p" -1
        else
            [ -n "$orig" ] || orig="$(cpu_min "$c")"
            _hy_w "$p" "$orig"
        fi
    done
    # CPU 上限写回不限，交还系统（下次正常接管时会按档位重写）
    ppm_release

    # ② GPU：写 0 = 解除固定（实测确认）
    [ -n "$HY_GPU_NODE" ] && _hy_w "$HY_GPU_NODE" 0

    # ③ DDR：见 _hy_ddr_release
    _hy_ddr_release

    rm -f "$HY_MARK" 2>/dev/null
    return 0
}

# 开机 / 卸载兜底：只要有痕迹就还原，无论如何都把标记清掉
hy_cleanup() {
    if [ -f "$HY_MARK" ] || [ -f "$HY_SAVED" ]; then
        hy_exit
    fi
    rm -f "$HY_MARK" "$HY_SAVED" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
hy_state() { # 当前状态行，给 ctl.sh / UI 用
    if [ -f "$HY_MARK" ]; then echo "满血中"; else echo "关闭"; fi
}

hy_state_line() {
    hy_detect >/dev/null 2>&1
    local g d c
    g="$([ -n "$HY_GPU_NODE" ] && echo 可用 || echo 本机无)"
    d="$([ -n "$HY_DDR_NODE" ] && echo 可用 || echo 本机无)"
    c="$([ -n "$HY_CPU_NODES" ] && echo 可用 || echo 本机无)"
    echo "状态=$(hy_state)  CPU下限=$c  GPU锁频=$g  DDR锁频=$d"
}

hy_gpu_node() { hy_detect_gpu >/dev/null 2>&1; [ -n "$HY_GPU_NODE" ] && echo "$HY_GPU_NODE" || echo "(本机无)"; }
hy_ddr_node() { hy_detect_ddr >/dev/null 2>&1; [ -n "$HY_DDR_NODE" ] && echo "$HY_DDR_NODE" || echo "(本机无)"; }

# 应用失败项（没做完的会在 UI 上标出来，不谎报成功）
hy_fails() {
    [ -f "$HY_MARK" ] && cat "$HY_MARK" 2>/dev/null | tr -d '\n' || true
}
