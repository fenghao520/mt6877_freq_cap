#!/system/bin/sh
# MODDIR 用 dirname + 绝对路径回退，不用 ${0%/*}：
# 后者在「不带斜杠的相对路径」调用下会原样返回脚本名，导致 util.sh 加载失败、整个开机流程失效。
MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules/mt6877_freq_cap"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules_update/mt6877_freq_cap"
[ -d "$MODDIR/scripts" ] || exit 0
. "$MODDIR/scripts/util.sh"
. "$MODDIR/scripts/dsleep.sh"

# 等待开机完成
i=0
until [ "$(getprop sys.boot_completed)" = "1" ] || [ "$i" -ge 75 ]; do
    sleep 2
    i=$((i + 1))
done

# 等待外部存储就绪（配置目录在 /sdcard）
i=0
until [ -d /storage/emulated/0/Android ] || [ "$i" -ge 60 ]; do
    sleep 2
    i=$((i + 1))
done

ensure_cf

# 深度睡眠残留清理：settings 里的 device_idle_constants 与 Doze 白名单是持久化数据，
# 若上次是「深睡中断电/强杀」而没走完还原流程，重启后必须照快照补还原，
# 否则缩短过的常量会一直生效、系统会一直过度休眠。
ds_cleanup

kill_daemon

# 起飞前先按日用档兜一次底
sh "$MODDIR/scripts/apply_once.sh" daily 2>/dev/null

# 启动守护（失败再试一次，仍失败则保持不限频，绝不影响开机）
start_daemon "$MODDIR/scripts/daemon.sh" "$DAEMON_MARK"
if [ -z "$(daemon_pids)" ]; then
    start_daemon "$MODDIR/scripts/daemon.sh" "$DAEMON_MARK"
fi
[ -z "$(daemon_pids)" ] && ppm_release
exit 0
