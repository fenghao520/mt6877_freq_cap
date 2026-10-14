#!/system/bin/sh
# 卸载：完全恢复 CPU 频率上限到「不限」，停守护，无残留
#
# MODDIR 为什么不能写成 ${0%/*}：
#   脚本一旦被以「uninstall.sh」这种不带斜杠的相对路径调用，${0%/*} 会原样返回
#   「uninstall.sh」（没有斜杠可删）→ util.sh 加载失败 → CF_DIR / CMD_FILE 等变量
#   全为空 → 后面每条 rm 都变成 rm /custom_freq.conf 这种错误目标，清理「静默地全部跳过」。
#   实测过：该写法在 relative 调用下退出码仍是 0、还打印「DONE」，纯粹是假成功。
#   这里统一用 dirname 取绝对路径，并双层回退到固定安装位置，任何调用方式都能定位。
MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules/mt6877_freq_cap"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules_update/mt6877_freq_cap"
if [ -d "$MODDIR/scripts" ]; then
    . "$MODDIR/scripts/util.sh" 2>/dev/null
    . "$MODDIR/scripts/dsleep.sh" 2>/dev/null
    . "$MODDIR/scripts/rrate.sh" 2>/dev/null
fi

# ① 先停守护，再动系统状态。
#    顺序很重要：若先还原、后杀守护，中间那几秒守护可能恰好又检测到熄屏并重新接管 Doze，
#    还原结果会被覆盖掉。守护先死，后面的还原才是终态。
[ -d "$MODDIR/scripts" ] && kill_daemon

# ② 频率恢复为 -1（不限）。不依赖 util.sh 是否加载成功 —— 即使脚本目录已经损坏，
#    也必须把频率放开，否则 CPU 会被一直压在上限直到重启。
for c in 0 1; do
    echo -1 > "/proc/ppm/policy/cluster_${c}_max_freq" 2>/dev/null
done

# ③ 深睡残留还原：照 ds/saved.conf 快照把 Doze 白名单与 device_idle_constants 逐项回滚。
#    ds_cleanup 内部对「无接管痕迹」的情况也会无条件解除 force-idle。
[ -d "$MODDIR/scripts" ] && ds_cleanup 2>/dev/null

# ③b 刷新率还原：min/peak_refresh_rate 同样是**持久化**设置，
#     不改回来，卸载后刷新率会被一直锁在 60Hz（用户还以为是系统坏了）。
[ -d "$MODDIR/scripts" ] && rr_cleanup 2>/dev/null

# ④ 清掉运行时文件
if [ -d "$MODDIR/scripts" ]; then
    rm -f "$CMD_FILE" "$STATE_FILE" "$DISABLE_FILE" "$DAEMON_PID_FILE" 2>/dev/null
    rm -f "$CF_DIR/rrate.held" "$CF_DIR/rrate.saved" 2>/dev/null
    rm -rf "$CF_DIR/ds" 2>/dev/null
fi
rm -f /data/adb/mt6877_freq_cap.daemon.lock 2>/dev/null

# 用户配置保留在 /sdcard/Android/mt6877_freq_cap（纯文本，重装可沿用；想彻底清除手动删该目录）
echo "DONE: 频率上限已恢复为不限(-1)"
exit 0
