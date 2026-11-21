#!/bin/bash
# =====================================================================
# 兼容入口：add-storcli-monitor.sh
#
# 从本版本开始，安装器更名为 install-storcli-monitor.sh。
# 为避免旧命令失效，此文件仅做转调。
# =====================================================================

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
installer="${script_dir}/install-storcli-monitor.sh"

echo "⚠️ add-storcli-monitor.sh 已升级为 install-storcli-monitor.sh, 正在转调..."
echo "   后续请直接执行: bash ${installer}"

if [ ! -f "$installer" ]; then
    echo -e "⛔ 未找到 ${installer}" >&2
    exit 1
fi

exec bash "$installer" "$@"
