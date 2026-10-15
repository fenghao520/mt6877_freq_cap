#!/system/bin/sh
# mtfcap-daemon · 天玑920限频守护进程
# 职责：前台应用识别 → 日用/游戏场景 → 档位 → 写入 MTK PPM 上限；熄屏自动解锁
# 档位来源：开机提速(前100秒) > 场景档位（mode.conf）；自定义频率在 util.sh 的 get_tier 里叠加
# 附加职责：深度睡眠（dsleep.sh）—— 熄屏未充电满宽限期后接管系统 Doze，亮屏/充电/放音立即还原
# 用 cd+dirname 取绝对路径（不是简单的 dirname "$0"/..）：
# 「不带斜杠的相对路径」调用时前者同样会算错，导致 util.sh 加载失败。
MODDIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules/mt6877_freq_cap"
. "$MODDIR/scripts/util.sh"
. "$MODDIR/scripts/dsleep.sh"
. "$MODDIR/scripts/rrate.sh"
. "$MODDIR/scripts/hyper.sh"

# 能力探测只做一次（要扫 /proc、/sys 的通配路径，不适合每轮跑），结果缓存给状态用
hy_detect >/dev/null 2>&1
HYC_GPU="$([ -n "$HY_GPU_NODE" ] && echo 1 || echo 0)"
HYC_DDR="$([ -n "$HY_DDR_NODE" ] && echo 1 || echo 0)"
HYC_CPU="$([ -n "$HY_CPU_NODES" ] && echo 1 || echo 0)"

# 记录自身 PID，供 kill_daemon / 状态查询精确定位（避免按字符串扫 cmdline 误伤其它进程）
echo $$ > "$DAEMON_PID_FILE" 2>/dev/null
chmod 0644 "$DAEMON_PID_FILE" 2>/dev/null

# 开机提速：用「系统开机时长」判定，而不是守护自己的启动时刻。
# 否则每次 WebUI 重启守护 / 更新模块都会白送 60 秒满血，违背「只有真开机才提速」。
BOOT_BOOST_UPTO=100    # /proc/uptime 小于该秒数时视为「刚开机」
TICK_ON=3              # 亮屏巡检间隔(秒)
TICK_OFF=12            # 熄屏巡检间隔(秒)
TICK_OFF_DS=3          # 深睡开启时的熄屏巡检间隔(秒)：保证宽限期内进入、亮屏 3 秒内还原
TICK_OFF_NIGHT=10      # 夜间(0~6点)熄屏巡检间隔(秒)：整夜巡检 3 秒一次太费，
                       # 夜里拿起手机最多晚 10 秒恢复限频，这个代价换整夜省电是划算的
# 前台应用缓存有效期。必须 < TICK_ON，否则「每 3 秒一轮」里会跳过扫描
# （原来是 4 秒：第 3 秒时 3<4 不扫、第 6 秒才扫 → 实际每两轮才识别一次前台，
#   游戏↔日用的场景切换要多等一轮，这就是「切了游戏但频率没跟上」的来源）。
FG_TTL=2               # 前台应用缓存有效期(秒)

uptime_sec() {
    local u
    u="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    case "$u" in ''|*[!0-9.]*) echo 99999 ;; *) echo "${u%.*}" ;; esac
}

LAST_SIG=""        # 上一次真正写入的签名（mode:scene:c0:c1）
RELEASED=0         # 熄屏释放标记
RELEASED_BY_CMD=0  # 手工「恢复不限」标记：保持放开直到场景/档位变化
REL_SIG=""         # 手工放开时的签名快照
NEED_REAPPLY=0     # 熄屏释放过 → 亮屏后必须重写一次
FG_PKG=""
FG_TS=0
DS_SINCE=""        # 本次熄屏起点（深睡宽限计时用；由 dsleep.sh 读取/清空）
PPM_FAIL=0         # 连续写 PPM 失败次数（≥3 才写进 state.conf 报警，偶发一次不惊动用户）
HY_TICK=0          # 满血自愈的 IO 复查节流计数
HY_FIXES=0         # 满血自愈次数（写进 state.conf，让用户看得见「自动修过几次」）
RR_NOW=""          # 刷新率「实际生效值」缓存（dumpsys 较重，节流刷新）
RR_SUP=""          # 本机支持的刷新率档位（只探一次就缓存）
RR_TICK=0

log_line() { # screen fg scene mode c0 c1 [disabled]
    local _i0 _i1 _warn="" _now=""
    # 配置目录万一被删掉，状态会写不进去、WebUI 一直显示「未运行」。
    # 这里补一次，省得用户看不出到底是守护挂了还是目录没了。
    [ -d "$CF_DIR" ] || mkdir -p "$CF_DIR" 2>/dev/null
    _i0="$(ppm_val 0)"; _i1="$(ppm_val 1)"

    # 写失败告警：连续失败才提示，偶发一次不值得吓唬用户
    if [ "${PPM_FAIL:-0}" -ge 3 ] 2>/dev/null; then _warn="ppm_write_fail"; fi

    # 刷新率的「实际生效值」要跑一次 dumpsys SurfaceFlinger --displays，比较重；
    # 只在功能开启时读，且每 5 轮（约 15 秒）才刷新一次，其余轮次用缓存值。
    if [ "$(rr_enabled)" = "1" ]; then
        RR_TICK=$((RR_TICK + 1))
        if [ -z "$RR_NOW" ] || [ "$RR_TICK" -ge 5 ]; then
            RR_TICK=0
            RR_NOW="$(rr_now)"
            [ -n "$RR_SUP" ] || RR_SUP="$(rr_supported)"
        fi
        _now="$RR_NOW"
    fi
    # 原子写入：先写临时文件再 rename，避免 WebUI 恰好 cat 到「刚被截断的空文件」
    # （/sdcard 上同一目录内 mv 是原子替换，读侧要么看到旧内容要么看到新内容）
    {
        echo "ts=$(date +%s)"
        echo "screen=$1"
        echo "fg=$2"
        echo "scene=$3"
        echo "mode=$4"
        echo "c0_target=$5"
        echo "c1_target=$6"
        echo "c0_now=$_i0"
        echo "c1_now=$_i1"
        echo "c0_hz=$(ppm_khz 0 "$_i0")"
        echo "c1_hz=$(ppm_khz 1 "$_i1")"
        echo "c0_cur=$(cpu_cur 0)"
        echo "c1_cur=$(cpu_cur 1)"
        echo "disabled=${7:-0}"
        echo "daemon=$$"
        # ---- 深度睡眠状态（WebUI「深睡」页读取）----
        echo "ds=$(ds_enabled)"
        echo "dsactive=$(ds_active)"
        echo "dsgrace=$(ds_grace)"
        echo "dswhite=$(ds_white_csv)"
        echo "dsw=$(ds_wake_csv)"
        echo "dswunit=$(ds_wake_unit)"
        # ---- 刷新率（WebUI「刷新率」页读取）----
        echo "rren=$(rr_enabled)"
        echo "rrdaily=$(rr_rate_for daily)"
        echo "rrgame=$(rr_rate_for game)"
        echo "rrheld=$(rr_holding)"
        echo "rrnow=$_now"
        echo "rrsup=$RR_SUP"
        echo "warn=$_warn"
        # ---- 实验功能（全部拉满）----
        echo "hy=$([ -f "$HY_MARK" ] && echo 1 || echo 0)"
        echo "hygpu=$HYC_GPU"
        echo "hyddr=$HYC_DDR"
        echo "hycpu=$HYC_CPU"
        echo "hyfail=$(hy_fails)"
        echo "hyfix=$(hy_fixes)"
    } > "$STATE_FILE.tmp" 2>/dev/null
    chmod 0644 "$STATE_FILE.tmp" 2>/dev/null
    mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null \
        || { # mv 失败（极少数情况）退回直接写，功能不受影响
             cat "$STATE_FILE.tmp" > "$STATE_FILE" 2>/dev/null
             rm -f "$STATE_FILE.tmp" 2>/dev/null
           }
    chmod 0644 "$STATE_FILE" 2>/dev/null
}

# 原子写 mode.conf。
# 直接 `> "$MODE_FILE"` 会先把文件截断成 0 字节再写 —— WebUI 每 900ms 读一次这个文件，
# 撞上这个窗口就会读到空内容，档位高亮瞬间跳回默认（看着像「改完又自己变回去」）。
mode_write() { # 日用档 游戏档
    printf 'mode_daily=%s\nmode_game=%s\n' "$1" "$2" > "$MODE_FILE.tmp" 2>/dev/null || return 1
    mv -f "$MODE_FILE.tmp" "$MODE_FILE" 2>/dev/null || {
        printf 'mode_daily=%s\nmode_game=%s\n' "$1" "$2" > "$MODE_FILE" 2>/dev/null
        rm -f "$MODE_FILE.tmp" 2>/dev/null
    }
    chmod 0666 "$MODE_FILE" 2>/dev/null
    return 0
}

process_cmd() {
    [ -s "$CMD_FILE" ] || return 0
    local line v d g _snap="$CF_DIR/cmd.snap"
    # 先把内容搬走、立刻清空命令文件，再慢慢处理。
    # 原来的写法是「while read < CMD_FILE ... 处理完才 : > CMD_FILE」——
    # 读取到清空之间有一个不小的窗口，WebUI 在这期间追加的命令会被静默丢掉
    # （表现为点了按钮没反应）。把清空提前，窗口就只剩一次 cat 的时间。
    # 另外 while 必须重定向而不是接管道：接管道会在子 shell 里跑，
    # 下面这些 LAST_SIG= / RELEASED_BY_CMD= 赋值全部丢失，命令等于白处理。
    # 快照失败就别清命令文件了，留到下一轮再试，总好过丢命令
    cat "$CMD_FILE" > "$_snap" 2>/dev/null || return 0
    : > "$CMD_FILE" 2>/dev/null
    # `|| [ -n "$line" ]` 不能省：文件最后一行若没有换行符，read 会返回非零
    # 但仍把内容写进 $line —— 光写 `while read -r line` 会直接跳过这一行，
    # 表现为「下发了一条命令却完全没生效」。
    while read -r line || [ -n "$line" ]; do
        case "$line" in
            mode_daily=*)
                v="${line#mode_daily=}"
                case "$v" in powersave|balance|performance|fast)
                    g="$(get_mode game)"
                    mode_write "$v" "$g"
                    # 用户显式选档 = 要求接管：清掉缓存签名与手工放开标记，
                    # 即使选的是当前同一档位也会真正重写一次
                    LAST_SIG=""; RELEASED_BY_CMD=0 ;;
                esac ;;
            mode_game=*)
                v="${line#mode_game=}"
                case "$v" in powersave|balance|performance|fast)
                    d="$(get_mode daily)"
                    mode_write "$d" "$v"
                    LAST_SIG=""; RELEASED_BY_CMD=0 ;;
                esac ;;
            disable) : > "$DISABLE_FILE" 2>/dev/null ;;
            enable)  rm -f "$DISABLE_FILE" 2>/dev/null; RELEASED_BY_CMD=0; LAST_SIG="" ;;
            # 「立即恢复不限」= 保持放开，直到场景/档位发生变化或被显式关闭
            # （否则守护下一轮就会因为「值没变」而拒绝重写，状态与意图不符）
            # REL_SIG 留空 → 下一轮用当时真实签名做快照，这样熄屏/亮屏不会误取消放开
            restore) RELEASED_BY_CMD=1; REL_SIG=""; ppm_release ;;
            # 立即按当前场景/档位重新接管一次（ctl.sh apply 用）
            apply)   RELEASED_BY_CMD=0; LAST_SIG="" ;;
            restart) RESTART=1 ;;
            # ---- 深度睡眠 ----
            ds=*)     ds_set_enable "${line#ds=}" ;;
            dsadd=*)  ds_white_add "${line#dsadd=}" ;;
            dsdel=*)  ds_white_del "${line#dsdel=}" ;;
            dsnow)    DS_SINCE="$(date +%s)"; ds_enter ;;
            dsexit)   ds_exit ;;
            # ---- 刷新率 ----
            rr=*)      rr_conf_set enable "${line#rr=}" ;;
            rrdaily=*) rr_conf_set daily "${line#rrdaily=}" ;;
            rrgame=*)  rr_conf_set game  "${line#rrgame=}"  ;;
            # ---- 实验功能（全部拉满）----
            hyper=*)   hy_conf_set "${line#hyper=}" ;;
            stop)    ds_exit; rr_drop; hy_exit; ppm_release; rm -f "$DAEMON_PID_FILE" 2>/dev/null; exit 0 ;;
        esac
    done < "$_snap"
    rm -f "$_snap" 2>/dev/null
    return 0
}

while true; do
    # 1) 处理 WebUI / CLI 下发的命令。
    #    必须放在总开关判断之前——否则一旦进入「停用」，守护就不再读命令，
    #    WebUI 的「恢复限频」将永远无法生效（死锁）。
    RESTART=0
    process_cmd
    if [ "$RESTART" = "1" ]; then
        # 拉起新守护并自验：只有新守护确实写下自己的 PID 才退出旧实例，
        # 否则留在原地继续工作，绝不出现「重启后没有守护」的空窗
        rm -f "$DAEMON_PID_FILE" 2>/dev/null
        setsid "$DAEMON_SCRIPT" "$DAEMON_MARK" >/dev/null 2>&1 </dev/null &
        sleep 2
        _np="$(tr -d ' \t\r\n' < "$DAEMON_PID_FILE" 2>/dev/null)"
        case "$_np" in ''|*[!0-9]*) _np="" ;; esac
        [ -n "$_np" ] && [ "$_np" != "$$" ] && exit 0
        # 新守护没起来 → 收回 PID 文件继续干活，绝不空窗
        echo $$ > "$DAEMON_PID_FILE" 2>/dev/null
        continue
    fi

    # 2) 总开关：disable 文件存在即完全交还系统
    if [ -f "$DISABLE_FILE" ]; then
        if [ "$RELEASED" != "1" ]; then
            ppm_release
            RELEASED=1
            LAST_SIG=""
        fi
        # 停用必须顺带退出深睡。
        # 这个分支排在「屏幕判断」之前，而 ds_on_tick / ds_off_tick 都在后面 ——
        # 不放这里的话，深睡中按下「停用」会让 force-idle 与缩短过的
        # device_idle_constants 一直留在系统里，连亮屏都不会还原（手机像卡住），
        # 而且设置里还显示着「已停用」，用户根本无从判断是模块干的。
        [ -f "$DS_ACT" ] && ds_exit
        # 刷新率同理：停用就该把控制权还给系统，不然「刷新率锁定」会一直留着
        rr_drop
        # 实验功能更要还原：它改的是 CPU 上下限 + GPU/DDR 档位，留着会一直满血
        [ -f "$HY_MARK" ] && hy_exit
        log_line off "" "" "" -1 -1 1
        sleep 10
        continue
    fi

    # 3) 熄屏：解除限频，交还系统调度；顺便走深度睡眠判定
    if ! screen_on; then
        if [ "$RELEASED" != "1" ]; then
            ppm_release
            RELEASED=1
            NEED_REAPPLY=1   # 不用清 LAST_SIG：亮屏时再清，避免手动的「恢复不限」被熄屏顺带取消
            rr_drop          # 熄屏时锁刷新率没意义，交还系统让息屏显示/低功耗自己决定
        fi
        log_line off "" "" "" -1 -1 0
        if [ "$(ds_enabled)" = "1" ]; then
            # 深睡开启：熄屏期间以 3 秒粒度巡检。
            # ds_off_tick 是非阻塞的（每轮只判断一次、靠 DS_SINCE 跨轮计时），
            # 所以宽限期等待期间主循环照样转 → 命令照常处理、亮屏 3 秒内还原，
            # 同时「熄屏满 20 秒进入深睡」也仍然成立。
            ds_off_tick
            # 夜间放宽：整夜每 3 秒巡检一次太费电，0~6 点放宽到 10 秒。
            # 深睡宽限计时靠 DS_SINCE 跨轮累计，所以放宽不影响「熄屏满 20 秒进深睡」，
            # 代价只是夜里拿起手机后恢复限频最多晚 10 秒。
            if is_night; then
                sleep "$TICK_OFF_NIGHT"
            else
                sleep "$TICK_OFF_DS"
            fi
        else
            sleep "$TICK_OFF"
        fi
        continue
    fi
    RELEASED=0
    ds_on_tick   # 亮屏：若还在深睡，立即把 Doze 常量与白名单逐项还原
    if [ "$NEED_REAPPLY" = "1" ]; then
        LAST_SIG=""
        NEED_REAPPLY=0
    fi

    # 4) 场景识别
    now="$(date +%s)"
    if [ $((now - FG_TS)) -ge "$FG_TTL" ]; then
        FG_PKG="$(foreground_pkg)"
        FG_TS="$now"
    fi
    if [ -n "$FG_PKG" ] && is_game "$FG_PKG"; then
        scene=game
    else
        scene=daily
    fi

    # 4.5) 实验功能（全部拉满）：优先级最高 —— 开启后直接覆盖日用/游戏，跳过整套档位计算。
    #      CPU 两簇写硬件最大 + GPU/DDR 锁最高档，都在 hy_enter 里完成。
    if [ "$(hy_enabled)" = "1" ]; then
        if [ ! -f "$HY_MARK" ]; then
            hy_enter
        else
            # 自愈复查：满血状态一旦被外部冲掉（别处调一次 ppm_release、或某次写入
            # 半途失败），「只在开启时应用一次」的写法就再也回不来 ——
            # 用户看到的现象是「开关明明开着，下限却是 -1」。
            # CPU 只读 4 个 /proc 节点，很便宜 → 每轮查；
            # GPU/DDR 要读完整 dvfsrc_dump，较贵 → 每 5 轮查一次。
            HY_TICK=$((HY_TICK + 1))
            if hy_verify_cpu; then
                if [ "$HY_TICK" -ge 5 ]; then
                    HY_TICK=0
                    if ! hy_verify_io; then
                        hy_apply >/dev/null 2>&1
                        HY_FIXES=$((HY_FIXES + 1))
                    fi
                fi
            else
                hy_apply >/dev/null 2>&1
                HY_FIXES=$((HY_FIXES + 1))
            fi
        fi
        # 刷新率按「游戏档」取值 —— 跑分当然要最高刷，不能被日用档的 60Hz 压住
        if [ "$(rr_enabled)" = "1" ]; then
            rr_take "$(rr_rate_for game)"
        else
            rr_drop
        fi
        log_line on "$FG_PKG" hyper hyper "$(cpu_max 0)" "$(cpu_max 1)" 0
        sleep "$TICK_ON"
        continue
    fi
    # 关掉之后要把满血交还（只做一次：标记文件没了就不会再进来）
    # 必须同时清掉 LAST_SIG：hy_exit 会把上限写回 -1，而此刻算出来的目标值
    # 与 hyper 之前的签名**完全相同** → 「值没变就不重写」的优化会让它跳过，
    # 结果上限一直停在「不限」，直到场景或档位变化才恢复。
    if [ -f "$HY_MARK" ]; then
        hy_exit
        LAST_SIG=""
    fi

    # 5) 档位：开机提速 > 场景全局档位
    #    PINNED=1 表示这是「开机提速」，此时不套用自定义频率
    PINNED=1
    if [ "$(uptime_sec)" -lt "$BOOT_BOOST_UPTO" ] 2>/dev/null; then
        mode=fast
    else
        mode="$(get_mode "$scene")"
        PINNED=0
    fi

    # 6) 计算目标值（0 表示该簇不限频，由 ppm_set 转成 -1）
    c0="$(get_tier "$mode" "$scene" 0 "$PINNED")"
    c1="$(get_tier "$mode" "$scene" 1 "$PINNED")"
    case "$c0" in ''|*[!0-9]*) c0="$(cpu_max 0)" ;; esac
    case "$c1" in ''|*[!0-9]*) c1="$(cpu_max 1)" ;; esac

    # 7) 手工「恢复不限」后保持放开；一旦场景/档位变化立即重新接管
    sig="${mode}:${scene}:${c0}:${c1}"
    if [ "$RELEASED_BY_CMD" = "1" ]; then
        if [ -z "$REL_SIG" ]; then
            REL_SIG="$sig"
            ppm_release
        elif [ "$sig" != "$REL_SIG" ]; then
            RELEASED_BY_CMD=0
        else
            ppm_release
        fi
    fi

    # 8) 仅变化时写入，避免无谓的内核调用
    if [ "$RELEASED_BY_CMD" != "1" ] && [ "$sig" != "$LAST_SIG" ]; then
        # 两簇都写成功才记签名。任何一次偶发失败都不能被当成成功 ——
        # 否则「值没变 → 不重写」的优化会让它永久不再补写，表现为改了不生效。
        if ppm_set 0 "$c0" && ppm_set 1 "$c1"; then
            LAST_SIG="$sig"
            PPM_FAIL=0
        else
            LAST_SIG=""    # 留空 → 下一轮重新尝试
            PPM_FAIL=$((PPM_FAIL + 1))
        fi
    fi

    # 9) 刷新率：按当前场景锁定（功能关闭时立即交还）
    #    rr_take 是幂等的（先比对已锁值），所以每轮调用只是读一个小文件，很便宜。
    if [ "$(rr_enabled)" = "1" ]; then
        if [ "$scene" = game ]; then
            rr_take "$(rr_rate_for game)"
        else
            rr_take "$(rr_rate_for daily)"
        fi
    else
        # 功能关闭 → 彻底交还（连快照一起清掉，见 rrate.sh 里的说明）。
        # 加个存在性判断，避免每轮都白跑两个 test。
        if [ -f "$RR_HELD" ] || [ -f "$RR_SAVED" ]; then rr_handback; fi
    fi

    log_line on "$FG_PKG" "$scene" "$mode" "$c0" "$c1" 0
    sleep "$TICK_ON"
done
