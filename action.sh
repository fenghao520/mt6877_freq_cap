#!/system/bin/sh
# KernelSU 执行按钮 / WebUI 入口
# MODDIR 用 dirname + 绝对路径回退，不用 ${0%/*}：
# 后者在「不带斜杠的相对路径」调用下会原样返回脚本名（没有斜杠可删），
# 于是 scripts/util.sh 加载失败、后面的 ppm 节点路径全空，整个脚本静默失效。
# 其余入口（uninstall/service/daemon/ctl/apply_once）都已改，这里补齐。
MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules/mt6877_freq_cap"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules_update/mt6877_freq_cap"
. "$MODDIR/scripts/util.sh"

_menu() { echo "$*"; }

_menu "======================================="
_menu "     天玑920限频 · 快捷操作"
_menu "======================================="
_menu "   [音量+]  切换模式（日用/游戏）"
_menu "   [音量-]  卸载并恢复频率"
_menu "======================================="
_menu "  （15 秒内未按则自动取消）"

key="$(key_press 15)"

if [ "$key" = down ]; then
    _menu " "
    _menu "  >> 即将卸载并恢复频率上限…"
    sleep 1
    sh "$MODDIR/uninstall.sh"
    _menu "  >> 完成：$([ -e "$(ppm_node 0)" ] && cat "$(ppm_node 0)")"
    exit 0
fi

_menu " "
_menu "  请选择要设置哪个全局："
_menu "   [音量+] 日用全局"
_menu "   [音量-] 游戏全局"
slotkey="$(key_press 15)"
case "$slotkey" in
    up)   SLOT=daily; SLOTCN=日用 ;;
    down) SLOT=game;  SLOTCN=游戏 ;;
    *)    _menu "  >> 操作超时，已取消"; exit 0 ;;
esac

_menu " "
_menu "  请选择档位："
_menu "   [音量+] 省电 / 极速"
_menu "   [音量-] 均衡 / 性能"
g="$(key_press 15)"
case "$g" in
    up)
        _menu "   [音量+] 省电   [音量-] 极速"
        m2="$(key_press 15)"
        case "$m2" in up) sel=powersave ;; down) sel=fast ;; *) sel="" ;; esac
        ;;
    down)
        _menu "   [音量+] 均衡   [音量-] 性能"
        m2="$(key_press 15)"
        case "$m2" in up) sel=balance ;; down) sel=performance ;; *) sel="" ;; esac
        ;;
esac
[ -z "$sel" ] && { _menu "  >> 操作超时，已取消"; exit 0; }

d="$(get_mode daily)"; gg="$(get_mode game)"
if [ "$SLOT" = daily ]; then d="$sel"; else gg="$sel"; fi
mkdir -p "$CF_DIR" 2>/dev/null
# 原子写：先写临时文件再 mv。直接 > 会先把文件截断成 0 字节，
# 守护（每 3 秒）或 WebUI（每 900ms）撞上这个窗口就会读到空文件。
printf 'mode_daily=%s\nmode_game=%s\n' "$d" "$gg" > "$MODE_FILE.tmp" 2>/dev/null \
    && mv -f "$MODE_FILE.tmp" "$MODE_FILE" 2>/dev/null \
    || printf 'mode_daily=%s\nmode_game=%s\n' "$d" "$gg" > "$MODE_FILE" 2>/dev/null
chmod 0666 "$MODE_FILE" 2>/dev/null

_menu " "
_menu "  >> ${SLOTCN}全局已设为：$(_mcn "$sel")"
_menu "  >> 正在应用…"
# 必须应用「刚改的那个场景」。原来这里写死 daily：
# 用户明明选的是游戏档，却按日用档去应用，等于改完当场不生效。
sh "$MODDIR/scripts/apply_once.sh" "$SLOT" 2>/dev/null
_menu "  >> 完成"
