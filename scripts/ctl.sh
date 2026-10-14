#!/system/bin/sh
# 命令行控制台：sh ctl.sh <命令> [参数]
#   status              查看当前状态
#   dryrun [模式]        只算不写，预览将要写入的值（安全校验用）
#   mode <daily|game> <powersave|balance|performance|fast>
#   apply [daily|game]   立即应用一次
#   restore             立即恢复不限(-1)
#   disable / enable     总开关
#   restart             重启守护
#   stop                停守护并恢复
#   ds on|off|status    深度睡眠开关 / 查看
#   ds enter|exit       立即进入 / 立即还原（调试用）
#   dswhite list|add <包名>|del <包名>   深睡白名单
#   rr on|off|status    刷新率管理开关 / 查看
#   rr daily <Hz>       设置日用场景锁定的刷新率
#   rr game <Hz>        设置游戏场景锁定的刷新率
# （频率微调请在 WebUI「频率」页操作：全局自定义 custom_freq.conf / 档位覆盖 tier_freq.conf）
# 用 cd+dirname 取绝对路径：支持「cd 到脚本目录后 sh ctl.sh」这类相对调用
MODDIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules/mt6877_freq_cap"
. "$MODDIR/scripts/util.sh"
. "$MODDIR/scripts/dsleep.sh"
. "$MODDIR/scripts/rrate.sh"

# tier_freq.conf 里的有效覆盖项数。
# 注意不能写成 `grep -c ... || echo 0`：grep -c 在无匹配时会「打印 0 并返回非零」，
# 于是 0 会被打印两次（一行 0、一行 0 项）。
tier_count() {
    local n
    n="$(grep -ciE '^(POWERSAVE|BALANCE|PERFORMANCE|FAST)_' "$TIER_FILE" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    echo "$n"
}

# 生效白名单条数（已安装的才算）。空列表时 awk 会读到空行导致输出为空，
# 所以这里显式兜 0，避免 status 显示成「白名单:  个」。
ds_white_n() {
    local v
    v="$(ds_white_effective)"
    if [ -z "$v" ]; then echo 0; else printf '%s' "$v" | awk -F, '{print NF}'; fi
}

CMD="$1"
case "$CMD" in
    status)
        _c0="$(ppm_val 0)"; _c1="$(ppm_val 1)"
        if [ -f "$DISABLE_FILE" ]; then RS=已停用
        elif [ "$_c0" = "-1" ] && [ "$_c1" = "-1" ]; then RS=已放开\(不限\)
        else RS=限频中; fi
        echo "SoC      : $(detect_soc) / $(_soc_platform_get)"
        echo "守护     : $([ -n "$(daemon_pids)" ] && echo 运行中 || echo 未运行)"
        echo "总开关   : $([ -f "$DISABLE_FILE" ] && echo 已停用 || echo 启用)"
        echo "放开状态 : $RS"
        echo "屏幕     : $(screen_on && echo 亮 || echo 灭)"
        echo "前台     : $(foreground_pkg)"
        echo "模式     : 日用=$(get_mode daily) / 游戏=$(get_mode game)"
        echo "自定义   : $([ "$(_conf_val "$CF_FILE" ENABLE 0)" = "1" ] && echo 启用 || echo 关闭)   档位覆盖: $(tier_count) 项"
        if [ "$(ds_enabled)" = "1" ]; then
            if [ "$(ds_active)" = "1" ]; then DSL=开启\(深睡中\); else DSL=开启\(待命\); fi
        else
            DSL=关闭
        fi
        echo "深度睡眠 : $DSL   白名单: $(ds_white_n) 个   宽限: $(ds_grace) 秒"
        if [ "$(rr_enabled)" = "1" ]; then
            echo "刷新率   : 开启 日用$(rr_rate_for daily)Hz/游戏$(rr_rate_for game)Hz   $(rr_state_line)  实际生效=$(rr_now)Hz  支持=$(rr_supported)"
        else
            echo "刷新率   : 关闭   支持=$(rr_supported)"
        fi
        echo "cluster0 : A55 上限=$(ppm_khz 0) kHz (节点索引=$_c0)  当前频率=$(cpu_cur 0) kHz  硬件最大=$(cpu_max 0)"
        echo "cluster1 : A78 上限=$(ppm_khz 1) kHz (节点索引=$_c1)  当前频率=$(cpu_cur 1) kHz  硬件最大=$(cpu_max 1)"
        ;;
    dryrun)
        MODE="$2"; [ -z "$MODE" ] && MODE="$(get_mode daily)"
        CUST="$(_conf_val "$CF_FILE" ENABLE 0)"
        if [ "$CUST" = "1" ]; then CU=启用; else CU=关闭; fi
        echo "== DRY-RUN（只计算，不写入）模式=$MODE 自定义频率=$CU =="
        for sc in daily game; do
            for c in 0 1; do
                t="$(get_tier "$MODE" "$sc" $c)"
                case "$t" in ''|*[!0-9]*) t=0 ;; esac
                if [ "$t" = "0" ]; then
                    disp="不限(写 -1)"
                else
                    disp="$(clamp_freq $c "$t") kHz"
                fi
                extra=""
                [ "$CUST" = "1" ] && extra="  [档位表=$(get_tier "$MODE" "$sc" $c 1)]"
                echo "  cluster$c $sc: 生效上限=$disp  (硬件 $(cpu_min $c)~$(cpu_max $c))$extra"
            done
        done
        ;;
    mode)
        slot="$2"; v="$3"
        case "$slot" in daily|game) ;; *) echo "用法: ctl.sh mode <daily|game> <档位>"; exit 1 ;; esac
        case "$v" in powersave|balance|performance|fast) ;; *) echo "档位无效: $v"; exit 1 ;; esac
        mkdir -p "$CF_DIR" 2>/dev/null
        printf "mode_%s=%s\n" "$slot" "$v" >> "$CMD_FILE"
        echo "已下发命令，守护将在数秒内应用"
        ;;
    apply)
        # 守护在跑就走命令通道（顺带清掉「已恢复不限」标记，避免刚写进去又被放开）；
        # 守护没跑才直接写一次
        if [ -n "$(daemon_pids)" ]; then
            mkdir -p "$CF_DIR" 2>/dev/null
            echo apply >> "$CMD_FILE"
            echo "已通知守护按当前场景/档位重新接管"
        else
            sh "$MODDIR/scripts/apply_once.sh" "${2:-daily}"
        fi
        ;;
    restore)
        # 与 WebUI「立即恢复不限」保持一致：走守护命令通道，保持放开而不是下一轮被重新限频
        if [ -n "$(daemon_pids)" ]; then
            mkdir -p "$CF_DIR" 2>/dev/null
            echo restore >> "$CMD_FILE"
            echo "已通知守护恢复不限（保持放开，直至切档或切换场景；想持久关掉用 disable）"
        else
            ppm_release
            echo "已恢复：两簇上限 = -1（不限）"
        fi
        ;;
    disable)
        : > "$DISABLE_FILE"
        echo "已停用（守护将放开全部限制）"
        ;;
    enable)
        rm -f "$DISABLE_FILE"
        echo "已启用"
        ;;
    restart)
        kill_daemon
        start_daemon "$MODDIR/scripts/daemon.sh" "$DAEMON_MARK"
        echo "守护状态: $([ -n "$(daemon_pids)" ] && echo 运行中 || echo 未运行)"
        ;;
    stop)
        kill_daemon; ppm_release
        echo "已停止守护并恢复不限"
        ;;
    # ---------------- 深度睡眠 ----------------
    ds)
        sub="$2"
        has_d=0; [ -n "$(daemon_pids)" ] && has_d=1
        case "$sub" in
            on|1)
                if [ "$has_d" = "1" ]; then echo ds=1 >> "$CMD_FILE"; else ds_set_enable 1; fi
                echo "深度睡眠：已开启（熄屏 $(ds_grace) 秒且未充电时自动进入）" ;;
            off|0)
                if [ "$has_d" = "1" ]; then echo ds=0 >> "$CMD_FILE"; else ds_set_enable 0; fi
                echo "深度睡眠：已关闭（若正在深睡会立即还原）" ;;
            enter|now)
                if [ "$has_d" = "1" ]; then echo dsnow >> "$CMD_FILE"; else ds_enter; fi
                echo "已请求立即进入深睡" ;;
            exit|restore)
                if [ "$has_d" = "1" ]; then echo dsexit >> "$CMD_FILE"; else ds_exit; fi
                echo "已请求立即还原" ;;
            *)
                if [ "$(ds_enabled)" = "1" ]; then
                    if [ "$(ds_active)" = "1" ]; then EN=开启\(深睡中\); else EN=开启\(待命\); fi
                else EN=关闭; fi
                echo "开关     : $EN"
                echo "宽限     : $(ds_grace) 秒"
                echo "充电中   : $(ds_charging)"
                echo "放音中   : $(ds_music)"
                echo "系统常量 : $(ds_consts_get)"
                echo "生效白名单 ($(ds_white_n) 个): $(ds_white_effective)"
                if [ "$(ds_wake_unit)" = "wake" ]; then U=唤醒; else U=闹钟触发; fi
                echo "排行口径 : $U"
                echo "唤醒排行 : $(ds_wake_csv)"
                ;;
        esac ;;
    dswhite)
        sub="$2"
        has_d=0; [ -n "$(daemon_pids)" ] && has_d=1
        case "$sub" in
            add)
                p="$3"
                case "$p" in ''|*[!A-Za-z0-9._]*) echo "用法: ctl.sh dswhite add <包名>"; exit 1 ;; esac
                if [ "$has_d" = "1" ]; then echo "dsadd=$p" >> "$CMD_FILE"; else ds_white_add "$p"; fi
                echo "已加入白名单：$p" ;;
            del|rm)
                p="$3"
                case "$p" in ''|*[!A-Za-z0-9._]*) echo "用法: ctl.sh dswhite del <包名>"; exit 1 ;; esac
                if [ "$has_d" = "1" ]; then echo "dsdel=$p" >> "$CMD_FILE"; else ds_white_del "$p"; fi
                echo "已移出白名单：$p" ;;
            *)
                echo "配置白名单: $(ds_white_conf)"
                echo "生效白名单: $(ds_white_effective)" ;;
        esac ;;
    # ---------------- 刷新率 ----------------
    rr)
        sub="$2"
        case "$sub" in
            on|1)
                rr_conf_set enable 1
                echo "刷新率管理：已开启（亮屏时 日用锁 $(rr_rate_for daily)Hz / 游戏锁 $(rr_rate_for game)Hz；熄屏交还系统）" ;;
            off|0)
                rr_conf_set enable 0
                rr_handback
                echo "刷新率管理：已关闭，已还原为你原来的设置" ;;
            daily)
                v="$3"
                case "$v" in ''|*[!0-9]*) echo "用法: ctl.sh rr daily <Hz>"; exit 1 ;; esac
                rr_conf_set daily "$v"
                echo "日用场景已设为 ${v}Hz（本机支持: $(rr_supported)）" ;;
            game)
                v="$3"
                case "$v" in ''|*[!0-9]*) echo "用法: ctl.sh rr game <Hz>"; exit 1 ;; esac
                rr_conf_set game "$v"
                echo "游戏场景已设为 ${v}Hz（本机支持: $(rr_supported)）" ;;
            *)
                if [ "$(rr_enabled)" = "1" ]; then EN=开启; else EN=关闭; fi
                echo "开关       : $EN"
                echo "日用 / 游戏: $(rr_rate_for daily)Hz / $(rr_rate_for game)Hz"
                echo "本机支持   : $(rr_supported)"
                echo "当前生效   : $(rr_now)Hz"
                echo "锁定状态   : $(rr_state_line)"
                if [ -f "$RR_SAVED" ]; then
                    echo "原值快照   : $(sed -n 's/^min=/min=/p' "$RR_SAVED" | head -n1)  $(sed -n 's/^peak=/peak=/p' "$RR_SAVED" | head -n1)"
                else
                    echo "原值快照   : 无（未接管过，不会动你的设置）"
                fi
                ;;
        esac ;;
    *)
        sed -n '2,24p' "$0"
        ;;
esac
