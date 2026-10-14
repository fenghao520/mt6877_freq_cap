#!/system/bin/sh
# 立即应用一次指定场景的档位（不依赖守护）
# 用法：sh apply_once.sh [daily|game] [模式]
MODDIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -d "$MODDIR/scripts" ] || MODDIR="/data/adb/modules/mt6877_freq_cap"
. "$MODDIR/scripts/util.sh"

SCENE="${1:-daily}"
MODE="$2"
[ -z "$MODE" ] && MODE="$(get_mode "$SCENE")"

soc="$(detect_soc)"
[ -z "$soc" ] && soc=MT6877

c0="$(get_tier "$MODE" "$SCENE" 0)"
c1="$(get_tier "$MODE" "$SCENE" 1)"
case "$c0" in ''|*[!0-9]*) c0="$(cpu_max 0)" ;; esac
case "$c1" in ''|*[!0-9]*) c1="$(cpu_max 1)" ;; esac

ppm_set 0 "$c0"
ppm_set 1 "$c1"

echo "scene=$SCENE mode=$MODE soc=$soc"
echo "cluster0(A55) 目标=$(clamp_freq 0 "$c0") kHz  当前PPM=$(ppm_val 0)"
echo "cluster1(A78) 目标=$(clamp_freq 1 "$c1") kHz  当前PPM=$(ppm_val 1)"
exit 0
