#!/bin/bash
# =====================================================================
# 完整恢复 PVE 原始状态
#
# 适用场景：
#   - 多次执行 pve-manager-status.sh 后，旧 .bak 备份已经被“修改后的文件”污染
#   - 无法再通过 .bak 回滚到真正的初始状态
#
# 原理：
#   PVE 的原始文件来自 pve-manager / pve-i18n 软件包。
#   通过 apt-get install --reinstall 重新解包，可以覆盖所有被修改的
#   Nodes.pm、pvemanagerlib.js、pve-lang-zh_CN.js。
#   不依赖任何本地 .bak 备份。
#
# 用法：
#   bash restore-pve-original.sh          # 交互确认
#   bash restore-pve-original.sh --yes    # 非交互
# =====================================================================

set -u

nodes_file="${PVE_NODES_PM:-/usr/share/perl5/PVE/API2/Nodes.pm}"
js_file="${PVE_PVEMANAGERLIB:-/usr/share/pve-manager/js/pvemanagerlib.js}"
i18n_file="${PVE_I18N_CN:-/usr/share/pve-i18n/pve-lang-zh_CN.js}"

parser_file="/usr/local/bin/pve_storcli_parser.py"
updater_file="/usr/local/bin/pve_storcli_cache_updater.sh"
storcli_sudoers="/etc/sudoers.d/pve-storcli"
base_sudoers="/etc/sudoers.d/pve-manager-status"
cache_dir="/var/cache/pve-manager"
cache_file="${cache_dir}/storcli_status.cache"
legacy_cache_dir="/var/cache/pve-manager-status"
state_dir="/var/lib/pve-manager-status"
systemd_dir="/etc/systemd/system"
service_file="${systemd_dir}/pve-storcli-cache.service"
timer_file="${systemd_dir}/pve-storcli-cache.timer"
turbo_conf="/etc/modules-load.d/turbostat-msr.conf"

echo -e "\n🧨 完整恢复 PVE 原始状态"
echo -e "   将重新安装 pve-manager / pve-i18n，并清理所有自定义内容"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    exit 1
fi

if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "⛔ 未检测到 Proxmox VE 环境, 终止执行!"
    exit 1
fi

if [ "${1:-}" != "--yes" ]; then
    read -p "确认恢复吗? 这会覆盖 PVE 的 Nodes.pm / pvemanagerlib.js / 中文翻译 [y/N]:" para
    case "$para" in
        y|Y|yes|YES) ;;
        *) echo -e "\n🚫 操作取消, 未执行任何操作!"; exit 0 ;;
    esac
fi

# ==========================================
# 1. 停止并删除阵列卡监控定时器
# ==========================================
echo -e "\n⏱️ 正在停止阵列卡监控定时器:"

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now pve-storcli-cache.timer >/dev/null 2>&1 || true
    systemctl stop pve-storcli-cache.service >/dev/null 2>&1 || true
fi

rm -f "$timer_file" "$service_file"
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed pve-storcli-cache.service >/dev/null 2>&1 || true
fi
echo "已移除 pve-storcli-cache.timer / service ✅"

# ==========================================
# 2. 清理阵列卡监控自定义文件
# ==========================================
echo -e "\n🧹 正在清理阵列卡监控自定义文件:"

for file in "$parser_file" "$updater_file" "$storcli_sudoers" "$cache_file"; do
    if [ -e "$file" ]; then
        rm -f "$file" && echo "已删除: $file ✅"
    fi
done

for dir in "$legacy_cache_dir" "$state_dir"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir" && echo "已删除目录: $dir ✅"
    fi
done

if [ -d "$cache_dir" ]; then
    rmdir "$cache_dir" >/dev/null 2>&1 || true
fi

# ==========================================
# 3. 清理基础脚本添加的配置
# ==========================================
echo -e "\n🧹 正在清理基础脚本添加的配置:"

for file in "$base_sudoers" "$turbo_conf"; do
    if [ -e "$file" ]; then
        rm -f "$file" && echo "已删除: $file ✅"
    fi
done

# ==========================================
# 4. 重新安装 PVE 包，恢复原始文件
# ==========================================
echo -e "\n📦 正在重新安装 pve-manager / pve-i18n (恢复原始文件):"

if ! apt-get install --reinstall -y pve-manager pve-i18n; then
    echo -e "\n⛔ 软件包重装失败, 请检查 apt 源或网络后重试"
    echo -e "   可手动执行: apt-get install --reinstall -y pve-manager pve-i18n"
    exit 1
fi

# ==========================================
# 5. 删除所有旧备份（避免以后误用被污染的 .bak）
# ==========================================
echo -e "\n🗑️ 正在删除旧备份文件:"

for pattern in "${nodes_file}".*.bak "${js_file}".*.bak "${i18n_file}".*.bak; do
    if [ -e "$pattern" ]; then
        rm -f "$pattern" && echo "已删除: $pattern ✅"
    fi
done

# ==========================================
# 6. 校验是否还有残留
# ==========================================
echo -e "\n🔎 正在校验原始文件:"

leftover=0
if grep -q 'storcli_status' "$nodes_file" 2>/dev/null; then
    echo "⚠️ Nodes.pm 仍包含 storcli_status"
    leftover=1
fi
if grep -q "itemId: 'storcli_status'" "$js_file" 2>/dev/null; then
    echo "⚠️ pvemanagerlib.js 仍包含 storcli_status"
    leftover=1
fi
if grep -q "itemId: 'cpupower'" "$js_file" 2>/dev/null; then
    echo "⚠️ pvemanagerlib.js 仍包含 PVE-Manager-Status 的 cpupower 模块"
    leftover=1
fi

if [ "$leftover" -eq 1 ]; then
    echo -e "\n⚠️ 检测到残留, 建议再次执行: apt-get install --reinstall -y pve-manager pve-i18n"
else
    echo "PVE 原始文件校验通过, 未发现注入残留 ✅"
fi

# ==========================================
# 7. 重启服务
# ==========================================
echo -e "\n🔁 正在重启 pvedaemon / pveproxy:"

if command -v systemctl >/dev/null 2>&1; then
    if timeout 30s systemctl restart pvedaemon.service pveproxy.service; then
        echo "服务已重启 ✅"
    else
        echo -e "⚠️ 服务重启失败或超时, 请手动执行: systemctl restart pvedaemon pveproxy"
    fi
fi

# ==========================================
# 8. 完成
# ==========================================
echo -e "\n✅ PVE 原始状态恢复完成"

echo -e "\nℹ️ 说明:"
echo -e "   1. pve-manager / pve-i18n 已重新安装, PVE 原始文件已覆盖。"
echo -e "   2. 依赖包 (sudo/sysstat/lm-sensors/smartmontools/linux-cpupower) 不会自动卸载,"
echo -e "      它们可能被其他服务使用; 如需卸载请自行确认后执行 apt remove。"
echo -e "   3. pve-manager-status.sh 可能向 /etc/modules 追加过传感器驱动;"
echo -e "      为避免误删你原有的模块, 本脚本不自动修改 /etc/modules。"
echo -e "   4. 如安装过 it87-dkms, 也需要自行决定是否卸载。"

echo -e "\n♻️ 请使用 Ctrl + Shift + R 强制刷新浏览器缓存"
