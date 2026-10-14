SKIPUNZIP=0

. "$MODPATH/scripts/util.sh"
MODDIR="$MODPATH"

ui_print " "
ui_print "  天玑920限频（复刻若晴官调限频 v4.4）"
ui_print "  作者 fenghao · 改编自 ynltoto · 控制通道 MTK PPM"
ui_print " "

SOC="$(detect_soc)"
if [ -z "$SOC" ]; then
    ui_print "  ! 未识别到天玑920(mt6877) 系列，平台为：$(_soc_platform_get)"
    ui_print "  ! 如确认是同架构机型，可在模块目录 config/soc.override 写入 MT6877 后重装"
    ui_print " "
    abort
fi

kill_daemon 2>/dev/null
[ -n "$(daemon_pids)" ] || true
sleep 1

# 校验控制通道存在
MISS=0
for c in 0 1; do
    [ -e "/proc/ppm/policy/cluster_${c}_max_freq" ] || MISS=1
done
if [ "$MISS" = "1" ]; then
    ui_print "  x 未找到 /proc/ppm/policy/cluster_*_max_freq，内核不支持本通道"
    ui_print "  x 安装终止（不会改动任何系统文件）"
    ui_print " "
    abort
fi

ui_print "  -> SoC: $SOC · $(_soc_platform_get)"
ui_print "  -> cluster0(A55 小核) 上限 $(cpu_max 0) kHz"
ui_print "  -> cluster1(A78 大核) 上限 $(cpu_max 1) kHz"
ui_print "  -> 内置档位表上限 MHz（日用 小/大 | 游戏 小/大）"
i=1
for m in powersave balance performance fast; do
    ld="$(get_tier "$m" daily 0 1)"; bd="$(get_tier "$m" daily 1 1)"
    lg="$(get_tier "$m" game 0 1)";  bg="$(get_tier "$m" game 1 1)"
    ui_print "     $(_mcn $m)  $((ld / 1000))/$((bd / 1000)) | $((lg / 1000))/$((bg / 1000))"
    i=$((i + 1))
done
if [ "$(_conf_val "$CF_FILE" ENABLE 0)" = "1" ]; then
    ui_print "  ! 检测到你已启用自定义频率，实际生效值以自定义为准（优先级高于档位表）"
fi

if [ -f "$CF_DIR/mode.conf" ]; then
    ui_print "  -> 沿用你已保存的设置：日用$(_mcn "$(get_mode daily)") / 游戏$(_mcn "$(get_mode game)")"
else
    ui_print "  -> 默认 日用均衡 / 游戏极速（WebUI 可改）"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh"            0 0 0755
set_perm "$MODPATH/action.sh"             0 0 0755
set_perm "$MODPATH/uninstall.sh"          0 0 0755
set_perm "$MODPATH/scripts/util.sh"       0 0 0755
set_perm "$MODPATH/scripts/daemon.sh"     0 0 0755
set_perm "$MODPATH/scripts/dsleep.sh"     0 0 0755
set_perm "$MODPATH/scripts/apply_once.sh" 0 0 0755
set_perm "$MODPATH/scripts/ctl.sh"        0 0 0755

# 安装期先落一份配置，确保首次开机就有档位可用
mkdir -p "$CF_DIR" 2>/dev/null
chmod 0777 "$CF_DIR" 2>/dev/null
[ -f "$CF_DIR/mode.conf" ] || cp "$MODPATH/templates/mode.conf" "$CF_DIR/mode.conf" 2>/dev/null
chmod 0666 "$CF_DIR/mode.conf" 2>/dev/null
[ -f "$CF_DIR/dsleep.conf" ] || cp "$MODPATH/templates/dsleep.conf" "$CF_DIR/dsleep.conf" 2>/dev/null
chmod 0666 "$CF_DIR/dsleep.conf" 2>/dev/null
mkdir -p "$CF_DIR/ds" 2>/dev/null
chmod 0777 "$CF_DIR/ds" 2>/dev/null
[ -f "$CF_DIR/cmd" ] || : > "$CF_DIR/cmd" 2>/dev/null
chmod 0666 "$CF_DIR/cmd" 2>/dev/null

ui_print " "
ui_print "  v 安装完成，重启后生效"
ui_print "  v WebUI 配置；执行按钮：音量+ 切档 / 音量- 卸载"
ui_print "  v 深度睡眠：熄屏 20 秒未充电自动进深度休眠，白名单应用照常工作，"
ui_print "     亮屏 / 充电 / 放音立即还原（默认关闭，在 WebUI「深睡」页开启）"
ui_print "  v 失控兜底：/sdcard/Android/mt6877_freq_cap/disable 建个空文件即全放开"
ui_print " "
