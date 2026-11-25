#!/bin/bash
# =====================================================================
# 移除 PVE 登录后的“无有效订阅”弹窗（实验性）
#
# 说明：
#   - 只修改前端 proxmoxlib.js 中的订阅提示弹窗
#   - 不会绕过订阅校验，也不会启用企业源
#   - pve-manager / proxmox-widget-toolkit 升级后可能被覆盖，需要重新执行
# =====================================================================

set -u

proxmoxlib="${PVE_PROXMOXLIB:-/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js}"
backup_dir="${PVE_NAG_BACKUP_DIR:-/var/backups/pve-manager-status}"
backup_file="${backup_dir}/proxmoxlib.js.nag.bak"
restart_service="${PVE_NAG_RESTART:-1}"

if [ "${PVE_NAG_NO_ROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!" >&2
    exit 1
fi

usage() {
    cat <<'USAGE'
用法:
  bash remove-subscription-nag.sh             移除登录订阅弹窗
  bash remove-subscription-nag.sh --status    查看当前状态
  bash remove-subscription-nag.sh --restore   恢复原始弹窗

环境变量:
  PVE_PROXMOXLIB       指定 proxmoxlib.js 路径
  PVE_NAG_BACKUP_DIR   指定备份目录
  PVE_NAG_NO_ROOT=1    跳过 root 检查（仅测试用）
  PVE_NAG_RESTART=0    修改后不重启 pveproxy（仅测试用）
USAGE
}

check_file() {
    if [ ! -f "$proxmoxlib" ]; then
        echo -e "⛔ 未找到文件: $proxmoxlib" >&2
        exit 1
    fi
}

is_patched() {
    python3 - "$proxmoxlib" <<'PY' >/dev/null 2>&1
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="surrogateescape") as handle:
    text = handle.read()

pattern = r"void\s*\(\s*\{\s*title:\s*gettext\(\s*(['\"])No valid subscription\1\s*\)"
sys.exit(0 if re.search(pattern, text, re.S) else 1)
PY
}

restart_proxy() {
    if [ "$restart_service" = "0" ]; then
        echo "已跳过 pveproxy 重启 (PVE_NAG_RESTART=0)"
        return 0
    fi
    echo -e "\n🔁 正在重启 pveproxy.service:"
    if systemctl restart pveproxy.service; then
        echo "pveproxy 已重启 ✅"
    else
        echo -e "⚠️ pveproxy 重启失败，请手动执行: systemctl restart pveproxy"
        return 1
    fi
}

do_status() {
    check_file
    if is_patched; then
        echo "订阅弹窗: 已移除 ✅"
    elif grep -q "No valid subscription" "$proxmoxlib"; then
        echo "订阅弹窗: 原始状态（仍会显示）"
    else
        echo "订阅弹窗: 未在文件中找到相关代码，可能版本已变化"
    fi
}

do_restore() {
    check_file

    # 优先通过重新安装所属软件包恢复，避免把旧版本备份覆盖到新版本
    local pkg=""
    if command -v dpkg >/dev/null 2>&1; then
        pkg=$(dpkg -S "$proxmoxlib" 2>/dev/null | head -n1 | cut -d: -f1)
    fi

    if [ -n "$pkg" ] && command -v apt-get >/dev/null 2>&1; then
        echo "正在重装 $pkg 以恢复原始文件:"
        if apt-get install --reinstall -y "$pkg"; then
            echo "原始文件已恢复 ✅"
            restart_proxy || true
            return 0
        fi
        echo -e "⚠️ 重装 $pkg 失败，尝试使用备份恢复..."
    fi

    if [ -f "$backup_file" ]; then
        cp -a "$backup_file" "$proxmoxlib"
        echo "已从备份恢复: $backup_file ✅"
        restart_proxy || true
        return 0
    fi

    echo -e "⛔ 未找到备份，且无法通过 apt 重装恢复。请手动重装:"
    echo "   apt-get install --reinstall -y ${pkg:-proxmox-widget-toolkit}"
    exit 1
}

do_patch() {
    check_file

    if is_patched; then
        echo "订阅弹窗已经是移除状态，无需重复修改 ✅"
        return 0
    fi

    if ! grep -q "No valid subscription" "$proxmoxlib"; then
        echo -e "⛔ 未在 $proxmoxlib 中找到 'No valid subscription'"
        echo -e "   PVE 版本可能已变化，未做任何修改。"
        exit 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${proxmoxlib}.nag.XXXXXX") || {
        echo -e "⛔ 无法创建临时文件" >&2
        exit 1
    }

    if ! python3 - "$proxmoxlib" "$tmp_file" >/dev/null <<'PY'
import os
import re
import stat
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8", errors="surrogateescape") as handle:
    text = handle.read()

# 只替换带 “No valid subscription” 标题的那一个 Ext.Msg.show 调用
pattern = re.compile(
    r"Ext\.Msg\.show(\s*\(\s*\{\s*title:\s*gettext\(\s*(['\"])No valid subscription\2\s*\))",
    re.S,
)
new_text, count = pattern.subn(r"void\1", text, count=0)
if count == 0:
    print("pattern-not-found", file=sys.stderr)
    sys.exit(2)

with open(dst, "w", encoding="utf-8", errors="surrogateescape") as handle:
    handle.write(new_text)

# 保持原文件权限
mode = stat.S_IMODE(os.stat(src).st_mode)
os.chmod(dst, mode)
print(count)
PY
    then
        rm -f "$tmp_file"
        echo -e "⛔ 修改失败: 未匹配到订阅弹窗代码，未做任何修改。"
        exit 1
    fi

    if ! mkdir -p "$backup_dir"; then
        rm -f "$tmp_file"
        echo -e "⛔ 无法创建备份目录: $backup_dir" >&2
        exit 1
    fi
    if [ ! -f "$backup_file" ]; then
        if ! cp -a "$proxmoxlib" "$backup_file"; then
            rm -f "$tmp_file"
            echo -e "⛔ 备份失败，未修改文件: $proxmoxlib" >&2
            exit 1
        fi
        echo "已备份原始文件: $backup_file ✅"
    fi
    if ! mv -f "$tmp_file" "$proxmoxlib"; then
        rm -f "$tmp_file"
        echo -e "⛔ 写入失败，未修改文件: $proxmoxlib" >&2
        exit 1
    fi

    if is_patched; then
        echo "已移除登录订阅弹窗 ✅"
        echo -e "⚠️ 这是实验性修改，pve-manager / proxmox-widget-toolkit 升级后可能需要重新执行。"
        restart_proxy || true
    else
        echo -e "⛔ 修改后校验失败，请检查文件: $proxmoxlib"
        exit 1
    fi
}

case "${1:-}" in
    --status)
        do_status
        ;;
    --restore)
        do_restore
        ;;
    -h|--help)
        usage
        ;;
    "")
        do_patch
        ;;
    *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
esac
