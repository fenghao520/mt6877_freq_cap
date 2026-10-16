#!/system/bin/sh
# ============================================================================
# 刷新率管理（Refresh Rate）· 用 AOSP 标准设置项
#
#   为什么不用若晴那套 `service call SurfaceFlinger 1035`：
#     1035 是 MIUI / 澎湃专有的事务码，AOSP / crDroid 上不一定存在，
#     而且它不认负 id 清锁（会留残锁把屏幕钉死）。
#     而 `min_refresh_rate` / `peak_refresh_rate` 是 Android 11+ 的
#     **标准设置项**，本机实测有效、语义清晰、还原干净。
#
#   本机实测（Redmi Note 11 Pro+ / crDroid 16）：
#     支持档位  60 / 120，mode id 0 / 2
#     原值      min_refresh_rate=120.0，peak_refresh_rate=null（未设置）
#     写 peak=60 + min=60  → activeMode 立刻变成 vsyncRate=60.00 Hz
#
#   ⚠️ 安全性：`settings` 是**持久化**数据 —— 改完不还原，卸载重装后依然生效。
#      所以沿用深睡那套做法：动手前先把原值落盘（rrate.saved），
#      停用 / 熄屏 / 卸载 / 开机都会照它还原。
#      没有快照时**绝不**动用户的设置（这条是拿血换来的，别改）。
# ============================================================================

if [ -z "$CF_DIR" ]; then
    _rr_self_dir="$(dirname "$0")"
    . "$_rr_self_dir/util.sh" 2>/dev/null
fi

RR_FILE="$CF_DIR/rrate.conf"
RR_SAVED="$CF_DIR/rrate.saved"      # 原值快照（min/peak）
RR_HELD="$CF_DIR/rrate.held"        # 存在 = 正被本模块锁着，内容是锁定的 Hz

RR_DEF_DAILY=60
RR_DEF_GAME=120

# ---------------------------------------------------------------------------
# 配置读写（字符串型；util.sh 的 _conf_val 只认数字，这里要读 null 之类的原文）
# ---------------------------------------------------------------------------
_rr_str() { # 文件 键 默认值
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

# 原子写回配置项（保留注释与其它行）。必须 mv —— 直接 > 会先把文件截断成 0 字节，
# 守护每轮都在读它，撞上窗口就会拿到空配置。
rr_conf_set() { # 键 值
    local k="$1" v="$2" tmp
    mkdir -p "$CF_DIR" 2>/dev/null
    chmod 0777 "$CF_DIR" 2>/dev/null
    [ -f "$RR_FILE" ] || rr_conf_default
    tmp="$RR_FILE.tmp"
    if grep -qE "^[[:space:]]*$k[[:space:]]*=" "$RR_FILE" 2>/dev/null; then
        awk -v k="$k" -v v="$v" '{
                line=$0; sub(/[[:space:]]*#.*/,"",line); n=split(line,a,"=");
                if(n>=2){ k2=a[1]; gsub(/[[:space:]]/,"",k2); if(k2==k){ print k"="v; next } }
                print
            }' "$RR_FILE" > "$tmp" 2>/dev/null && {
            mv -f "$tmp" "$RR_FILE" 2>/dev/null || cat "$tmp" > "$RR_FILE" 2>/dev/null
        }
    else
        printf '%s=%s\n' "$k" "$v" >> "$RR_FILE"
    fi
    rm -f "$tmp" 2>/dev/null
    chmod 0666 "$RR_FILE" 2>/dev/null
}

rr_conf_default() {
    mkdir -p "$CF_DIR" 2>/dev/null
    cp "$MODDIR/templates/rrate.conf" "$RR_FILE" 2>/dev/null
    chmod 0666 "$RR_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 配置读取
# ---------------------------------------------------------------------------
rr_enabled() {
    case "$(_rr_str "$RR_FILE" enable 0)" in 1) echo 1 ;; *) echo 0 ;; esac
}

rr_rate_for() { # daily|game → Hz
    local slot="$1" def="$2" v
    [ -n "$def" ] || { [ "$slot" = game ] && def="$RR_DEF_GAME" || def="$RR_DEF_DAILY"; }
    v="$(_rr_str "$RR_FILE" "$slot" "$def")"
    case "$v" in ''|*[!0-9]*) echo "$def" ;; *) echo "$v" ;; esac
}

# ---------------------------------------------------------------------------
# 与系统交互
# ---------------------------------------------------------------------------
rr_now() { # 当前「实际生效」的刷新率（整数 Hz），读不到则空
    dumpsys SurfaceFlinger --displays 2>/dev/null \
        | sed -n 's/.*activeMode={[^}]*vsyncRate=\([0-9][0-9.]*\) Hz.*/\1/p' \
        | head -n1 | sed 's/\..*//'
}

rr_supported() { # 本机支持的档位，升序逗号分隔（如 60,120）
    dumpsys display 2>/dev/null \
        | sed -n 's/.*mSupportedRefreshRates=\[\([^]]*\)\].*/\1/p' | head -n1 \
        | tr ',' '\n' | tr -d ' ' | sed 's/\..*//' | awk 'NF' \
        | sort -n -u | tr '\n' ',' | sed 's/,$//'
}

_rr_put() { # 值(null=删除) 键名
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        settings delete system "$2" >/dev/null 2>&1
    else
        settings put system "$2" "$1" >/dev/null 2>&1
    fi
}

RR_ERR=""   # 快照/写入失败原因，导出到 state.conf 供 WebUI 明示

_rr_valid_value() { # settings get 的有效返回：数字/小数或 null（表示原本未设置）
    case "$1" in
        null) return 0 ;;
        ''|*[!0-9.]*) return 1 ;;
        *[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

_rr_snapshot_valid() { # 文件必须含有效 min 与 peak 两个原值
    local f="$1" mn pk
    [ -s "$f" ] || return 1
    mn="$(sed -n 's/^min=//p' "$f" 2>/dev/null | head -n1 | tr -d ' \t\r\n')"
    pk="$(sed -n 's/^peak=//p' "$f" 2>/dev/null | head -n1 | tr -d ' \t\r\n')"
    _rr_valid_value "$mn" && _rr_valid_value "$pk"
}

# 快照原值。只记一次 —— 否则第二次会把自己设的值当成「原值」。
# **失败就拒绝接管**：settings 是持久化状态，没有成功落盘的原值快照，
# 之后就无法安全还原；不能再像旧实现那样吞掉 mv 失败、照样改 min/peak。
rr_snapshot() {
    local mn pk tmp="$RR_SAVED.tmp"
    if [ -f "$RR_SAVED" ]; then
        if _rr_snapshot_valid "$RR_SAVED"; then RR_ERR=""; return 0; fi
        RR_ERR="snapshot_invalid"
        return 1
    fi
    mkdir -p "$CF_DIR" 2>/dev/null || { RR_ERR="snapshot_unwritable"; return 1; }
    mn="$(settings get system min_refresh_rate 2>/dev/null | tr -d ' \t\r\n')"
    pk="$(settings get system peak_refresh_rate 2>/dev/null | tr -d ' \t\r\n')"
    if ! _rr_valid_value "$mn" || ! _rr_valid_value "$pk"; then
        RR_ERR="snapshot_read_failed"
        return 1
    fi
    if ! printf 'ts=%s\nmin=%s\npeak=%s\n' "$(date +%s)" "$mn" "$pk" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        RR_ERR="snapshot_write_failed"
        return 1
    fi
    chmod 0666 "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; RR_ERR="snapshot_chmod_failed"; return 1; }
    mv -f "$tmp" "$RR_SAVED" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; RR_ERR="snapshot_rename_failed"; return 1; }
    chmod 0666 "$RR_SAVED" 2>/dev/null || { RR_ERR="snapshot_chmod_failed"; return 1; }
    if ! _rr_snapshot_valid "$RR_SAVED"; then
        rm -f "$RR_SAVED" 2>/dev/null
        RR_ERR="snapshot_verify_failed"
        return 1
    fi
    RR_ERR=""
    return 0
}

# 还原到快照里的原值。
# 没有快照就**什么都不做** —— 那是用户自己设的，没有证据不能动。
rr_release() {
    [ -f "$RR_SAVED" ] || { rm -f "$RR_HELD" 2>/dev/null; return 0; }
    _rr_put "$(sed -n 's/^min=//p'  "$RR_SAVED" | head -n1)" min_refresh_rate
    _rr_put "$(sed -n 's/^peak=//p' "$RR_SAVED" | head -n1)" peak_refresh_rate
    rm -f "$RR_HELD" 2>/dev/null
    return 0
}

rr_holding() { [ -f "$RR_HELD" ] && cat "$RR_HELD" 2>/dev/null | tr -d ' \t\r\n' || echo ""; }

# 锁定到指定 Hz（幂等：已经锁在同一个值就什么都不做）
rr_take() { # hz
    local hz="$1" cur
    [ -n "$hz" ] || return 1
    case "$hz" in *[!0-9]*) return 1 ;; esac
    cur="$(rr_holding)"
    [ "$cur" = "$hz" ] && return 0
    # 无法得到完整快照时绝不写系统设置。
    rr_snapshot || return 1
    # min/peak 任一写入失败，都立即按快照回滚；RR_SAVED 保留供下一轮重试。
    if ! _rr_put "$hz" peak_refresh_rate || ! _rr_put "$hz" min_refresh_rate; then
        rr_release
        RR_ERR="settings_write_failed"
        return 1
    fi
    if ! printf '%s' "$hz" > "$RR_HELD.tmp" 2>/dev/null \
       || ! mv -f "$RR_HELD.tmp" "$RR_HELD" 2>/dev/null; then
        rm -f "$RR_HELD.tmp" 2>/dev/null
        rr_release
        RR_ERR="held_marker_failed"
        return 1
    fi
    chmod 0666 "$RR_HELD" 2>/dev/null || { rr_release; RR_ERR="held_marker_failed"; return 1; }
    RR_ERR=""
    return 0
}

# 临时交还（熄屏用）：还原，但**保留快照**。
# 因为功能还开着，亮屏后还要锁回去，快照得留着当「原值」的凭据。
rr_drop() {
    [ -f "$RR_HELD" ] || return 0
    rr_release
    return 0
}

# 彻底交还（用户主动关闭本功能时用）：还原，并**把快照一起清掉**。
# 清快照是有意的 —— 交还之后，用户在系统设置里选的档位就成了新的「原值」；
# 下次再开启应该以那一刻的系统状态为准，而不是翻出上一轮的旧账去覆盖他。
rr_handback() {
    rr_release
    rm -f "$RR_SAVED" "$RR_HELD" 2>/dev/null
    return 0
}

# 开机 / 卸载时的兜底清理：不管有没有 held 标记，只要有快照就还原
rr_cleanup() {
    [ -f "$RR_SAVED" ] && rr_release
    rm -f "$RR_HELD" "$RR_SAVED" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 状态输出（给 state.conf / ctl.sh / WebUI 用）
# ---------------------------------------------------------------------------
rr_state_line() { # 当前是「锁在 NHz」还是「已交还」
    local h
    h="$(rr_holding)"
    if [ -n "$h" ]; then echo "锁定${h}Hz"; else echo "已交还"; fi
}
