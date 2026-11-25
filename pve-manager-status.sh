#!/bin/bash
# pve-manager-status.sh
# Last Modified: 2026-11-22 (cluster adaptation)
#
# 统一入口脚本:
#   bash pve-manager-status.sh                交互式菜单 (推荐)
#   bash pve-manager-status.sh install        基础监控 + 阵列卡监控
#   bash pve-manager-status.sh base           仅基础监控
#   bash pve-manager-status.sh storcli-install
#   bash pve-manager-status.sh storcli-uninstall
#   bash pve-manager-status.sh update-cache
#   bash pve-manager-status.sh status
#   bash pve-manager-status.sh restore
#   bash pve-manager-status.sh repo-fix       移除 PVE 企业订阅源
#   bash pve-manager-status.sh nag-fix        移除登录订阅弹窗
#
# 内部实现仍拆分为独立模块, 便于维护; 日常使用只需记住本入口。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
用法: bash pve-manager-status.sh [命令]

命令:
  install              安装基础监控 + 阵列卡监控 (推荐)
  base                 仅安装/重装基础监控
  storcli-install      仅安装阵列卡监控
  storcli-uninstall    卸载阵列卡监控, 恢复到安装阵列卡之前
  update-cache         立即刷新阵列卡 SMART 缓存
  status               查看安装/缓存/定时器状态
  restore              完整恢复 PVE 原始状态 (清除所有修改)
  repo-fix             移除 PVE 企业订阅源, 修复 apt update 401
  nag-fix              移除登录后的“无有效订阅”弹窗 (实验性)
  nag-restore          恢复登录订阅弹窗
  help                 显示本帮助

示例:
  bash pve-manager-status.sh                # 打开交互式菜单
  bash pve-manager-status.sh install
  bash pve-manager-status.sh status
  bash pve-manager-status.sh restore

不带参数且在终端中运行时会打开交互式菜单.
EOF
}

run_component() {
    local script="$1"
    shift
    if [ ! -f "$script" ]; then
        echo -e "⛔ 未找到组件脚本: ${script}" >&2
        exit 1
    fi
    exec bash "$script" "$@"
}

interactive_menu() {
    while true; do
        cat <<'EOF'
============================================================
 PVE-Manager-Status 交互式安装/维护
============================================================
  1) 一键安装/更新: 基础监控 + 阵列卡监控  (推荐)
  2) 仅安装/更新:   基础监控
  3) 仅安装/更新:   阵列卡监控
  4) 卸载阵列卡监控 (保留基础监控)
  5) 完整恢复 PVE 原始状态 (清除所有修改)
  6) 查看当前状态
  7) 立即刷新阵列卡缓存
  8) 移除 PVE 企业订阅源 (修复 apt update)
  9) 移除登录订阅弹窗 (实验性)
  0) 退出
============================================================
EOF
        read -r -p "请输入选项 [0-9]: " choice || exit 1
        case "$choice" in
            1) exec bash "$0" install --yes ;;
            2) exec bash "$0" base --yes ;;
            3) exec bash "$0" storcli-install ;;
            4) exec bash "$0" storcli-uninstall ;;
            5) exec bash "$0" restore ;;
            6) exec bash "$0" status ;;
            7) exec bash "$0" update-cache ;;
            8) exec bash "$0" repo-fix ;;
            9) exec bash "$0" nag-fix ;;
            0) echo -e "\n👋 已退出"; exit 0 ;;
            *) echo -e "⚠️ 无效选项, 请重新输入." ;;
        esac
    done
}

case "${1:-}" in
    help|-h|--help)
        usage
        exit 0
        ;;
    install|all)
        shift
        assume_yes=0
        for arg in "$@"; do
            if [ "$arg" = "--yes" ] || [ "$arg" = "-y" ]; then
                assume_yes=1
            fi
        done

        if [ "$assume_yes" -eq 0 ]; then
            read -p "确认安装基础监控 + 阵列卡监控? [y/N]:" para
            case "$para" in
                y|Y|yes|YES) ;;
                n|N|no|NO) echo -e "\n🚫 操作取消, 未执行任何操作!"; exit 0 ;;
                *) echo -e "\n⚠️ 无效输入, 未执行任何操作!"; exit 1 ;;
            esac
        fi

        echo -e "\n===== 1/2 基础硬件监控 ====="
        bash "$0" base --yes || {
            echo -e "⛔ 基础监控安装失败, 终止" >&2
            exit 1
        }
        echo -e "\n===== 2/2 阵列卡 SMART 监控 ====="
        run_component "${SCRIPT_DIR}/install-storcli-monitor.sh" "$@"
        ;;
    storcli-install|install-storcli)
        shift
        run_component "${SCRIPT_DIR}/install-storcli-monitor.sh" "$@"
        ;;
    storcli-uninstall|uninstall-storcli)
        shift
        run_component "${SCRIPT_DIR}/uninstall-storcli-monitor.sh" "$@"
        ;;
    restore|restore-original)
        shift
        run_component "${SCRIPT_DIR}/restore-pve-original.sh" "$@"
        ;;
    repo-fix|remove-enterprise|enterprise-repo)
        shift
        run_component "${SCRIPT_DIR}/remove-pve-enterprise-repo.sh" "$@"
        ;;
    nag-fix|remove-nag|subscription-nag)
        shift
        run_component "${SCRIPT_DIR}/remove-subscription-nag.sh" "$@"
        ;;
    nag-restore|restore-nag)
        shift
        run_component "${SCRIPT_DIR}/remove-subscription-nag.sh" --restore "$@"
        ;;
    update-cache|refresh-cache)
        if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/pve-storcli-cache.service ]; then
            if systemctl start pve-storcli-cache.service; then
                echo "缓存已刷新 ✅"
            else
                echo -e "⚠️ 服务刷新失败, 尝试直接执行更新器..."
                /usr/local/bin/pve_storcli_cache_updater.sh || exit 1
            fi
        elif [ -x /usr/local/bin/pve_storcli_cache_updater.sh ]; then
            /usr/local/bin/pve_storcli_cache_updater.sh || exit 1
        else
            echo -e "⛔ 未找到阵列卡缓存更新器, 请先执行: bash $0 storcli-install" >&2
            exit 1
        fi
        if [ -s /var/cache/pve-manager/storcli_status.cache ]; then
            echo "当前缓存: $(head -n1 /var/cache/pve-manager/storcli_status.cache | cut -c1-160)..."
        fi
        exit 0
        ;;
    status)
        echo -e "\n📊 PVE-Manager-Status 状态"
        if command -v pveversion >/dev/null 2>&1; then
            echo "PVE 版本: $(pveversion | awk -F'/' '{print $2}')"
        fi

        if [ -f /etc/systemd/system/pve-storcli-cache.timer ]; then
            echo "定时器: $(systemctl is-active pve-storcli-cache.timer 2>/dev/null || true)"
            systemctl list-timers pve-storcli-cache.timer --no-pager 2>/dev/null | head -n 2 || true
        else
            echo "定时器: 未安装"
        fi

        cache_file="/var/cache/pve-manager/storcli_status.cache"
        if [ -f "$cache_file" ]; then
            cache_line=$(head -n1 "$cache_file" 2>/dev/null)
            if [ -n "$cache_line" ]; then
                disk_count=$(( $(printf '%s' "$cache_line" | grep -o '||' | wc -l) + 1 ))
                echo "缓存: ${disk_count} 块盘, $(wc -c < "$cache_file" | tr -d ' ') bytes"
                echo "样例: $(printf '%s' "$cache_line" | cut -c1-160)..."
            else
                echo "缓存: 空 (当前无阵列卡硬盘, 或尚未刷新)"
            fi
        else
            echo "缓存: 不存在"
        fi

        if grep -q 'storcli_status' /usr/share/perl5/PVE/API2/Nodes.pm 2>/dev/null; then
            echo "Nodes.pm: 已注入"
        else
            echo "Nodes.pm: 未注入"
        fi

        if grep -q "itemId: 'storcli_status'" /usr/share/pve-manager/js/pvemanagerlib.js 2>/dev/null; then
            echo "pvemanagerlib.js: 已注入"
        else
            echo "pvemanagerlib.js: 未注入"
        fi

        for backup in /usr/share/perl5/PVE/API2/Nodes.pm.storcli.bak /usr/share/pve-manager/js/pvemanagerlib.js.storcli.bak; do
            [ -f "$backup" ] && echo "备份: $backup"
        done
        exit 0
        ;;
    base)
        shift
        ;;
    "")
        if [ -t 0 ]; then
            interactive_menu
        fi
        # 非交互环境保持原有行为: 仅基础监控
        ;;
    *)
        echo -e "⛔ 未知命令: $1" >&2
        usage
        exit 1
        ;;
esac

echo -e "\n🛠️ \033[1;33;41mPVE-Manager-Status v0.6.4 by MiKing233\033[0m"

echo -e "为你的 ProxmoxVE 节点概要页面添加扩展的硬件监控信息"
echo -e "OpenSource on GitHub (https://github.com/MiKing233/PVE-Manager-Status)\n"

# 先决条件执行判断
# 执行用户判断, 必须为 root 用户执行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    echo && exit 1
fi

# 执行环境判断, 必须为 Debian 发行版且存在 ProxmoxVE 环境
if ! command -v pveversion &> /dev/null; then
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
            echo -e "⛔ 检测到当前系统非 Debian 发行版, 终止执行!"
            echo && exit 1
        fi
    fi
    echo -e "⛔ 未检测到 ProxmoxVE 环境, 终止执行!"
    echo && exit 1
fi

# 脚本执行前确认
assume_yes=0
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
    assume_yes=1
    echo -e "已指定 --yes, 跳过基础脚本确认."
fi

if [ "$assume_yes" -eq 0 ]; then
    read -p "确认执行吗? [y/N]:" para
    [[ "$para" =~ ^[Yy]$ ]] || { [[ "$para" =~ ^[Nn]$ ]] && echo -e "\n🚫 操作取消, 未执行任何操作!\n" && exit 0; echo -e "\n⚠️ 无效输入, 未执行任何操作!\n"; exit 1; }
fi

nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
pve_i18n_CN="/usr/share/pve-i18n/pve-lang-zh_CN.js"
sata_parser_file="/usr/local/bin/pve_sata_parser.py"
pvever=$(pveversion | awk -F"/" '{print $2}')
pve_major_ver=$(echo "$pvever" | cut -d'.' -f1)

echo -e "\n⚙️ 当前 Proxmox VE 版本: $pvever"

####################   修改前重装软件包避免重复修改   ####################
# 注意: 必须先重装软件包, 再执行下面的备份步骤.
# 否则备份到的是上一次修改后的文件, 无法回滚到真正的原始状态.

spinner() {
    local pid=$1
    local text="$2"
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\r%s %s" "$text" "${spinstr:$i:1}"
            sleep $delay
        done
    done

    printf "\r%s " "$text"
}

echo -e "♻️ 正在重装相关软件包:"

reinstall_packages=(pve-manager pve-i18n)
reinstall_failed=()

for pkg in "${reinstall_packages[@]}"; do
    text="正在重装 $pkg:"

    apt-get install --reinstall -y "$pkg" >/dev/null 2>&1 &
    pid=$!

    spinner "$pid" "$text"

    wait $pid
    if [ $? -eq 0 ]; then
        echo "已完成 ✅"
    else
        echo "重装失败 ⛔"
        reinstall_failed+=("$pkg")
    fi
done

# 最终结果判断
if [ ${#reinstall_failed[@]} -ne 0 ]; then
    echo -e "\n⛔ 软件包重装失败! 请检查你的 apt 源配置或网络连接"
    echo && exit 1
else
    echo -e "相关软件包已重装完成!"
fi

echo && sleep 0.5

####################   配置文件备份步骤   ####################

echo -e "\n💾 正在备份原文件:"

delete_old_backups() {
    local pattern="$1"
    local description="$2"

    shopt -s nullglob
    local files=($pattern)
    shopt -u nullglob

    if [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            echo "旧备份清理: $file ♻️"
        done
        rm -f "${files[@]}"
    else
        echo "没有发现任何旧备份文件! ♻️"
    fi
}
echo -e "清理旧的备份文件..."
delete_old_backups "${nodes}.*.bak" "nodes"
delete_old_backups "${pvemanagerlib}.*.bak" "pvemanagerlib"
delete_old_backups "${pve_i18n_CN}.*.bak" "pve_i18n_CN"

echo -e "备份重装后的原始文件 (用于回滚到本次执行前的 PVE 原始状态)..."

cp "$nodes" "${nodes}.${pvever}.bak" || {
    echo "⛔ 备份失败: $nodes"
    exit 1
}
echo "新备份生成: ${nodes}.${pvever}.bak ✅"

cp "$pvemanagerlib" "${pvemanagerlib}.${pvever}.bak" || {
    echo "⛔ 备份失败: $pvemanagerlib"
    exit 1
}
echo "新备份生成: ${pvemanagerlib}.${pvever}.bak ✅"

cp "$pve_i18n_CN" "${pve_i18n_CN}.${pvever}.bak" || {
    echo "⛔ 备份失败: $pve_i18n_CN"
    exit 1
}
echo "新备份生成: ${pve_i18n_CN}.${pvever}.bak ✅"

echo && sleep 0.5

####################   软件包依赖检查   ####################

# 软件包依赖
echo -e "🗃️ 正在检查依赖软件包:"
dep_packages=(sudo sysstat lm-sensors smartmontools linux-cpupower python3)
dep_missing=()

# 检查依赖状态
installed_list=$(apt list --installed 2>/dev/null)
for pkg in "${dep_packages[@]}"; do
    if echo "$installed_list" | grep -q "^$pkg/"; then
        echo "$pkg: 已安装 ✅"
    else
        echo "$pkg: 未安装 ⛔"
        dep_missing+=("$pkg")
    fi
done

# 安装缺失的包
if [ ${#dep_missing[@]} -ne 0 ]; then
    echo -e "\n📦 检查到软件包缺失: ${dep_missing[*]} 开始安装..."
    if ! (apt-get update && apt-get install -y "${dep_missing[@]}"); then
        echo -e "\n⛔ 依赖软件包安装失败! 请检查你的 apt 源配置或网络连接"
        echo && exit 1
    fi
    echo -e "✅ 依赖软件包已成功安装!"
else
    echo -e "所有依赖软件包均已安装!"
fi

echo && sleep 0.5

####################   配置设备传感器模块   ####################

echo -e "🧰 正在配置设备传感器模块:"
sensors-detect --auto > /tmp/sensors

drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d;/cut/d')

if [ -n "$drivers" ]; then
    echo "发现传感器模块, 正在配置开机自动加载"
    for drv in $drivers; do
        modprobe "$drv"
        if grep -qx "$drv" /etc/modules; then
            echo "模块 $drv 已存在于 /etc/modules ➡️"
        else
            echo "$drv" >> /etc/modules
            echo "模块 $drv 已添加至 /etc/modules ✅"
        fi
    done
    if [[ -e /etc/init.d/kmod ]]; then
        echo "正在应用模块配置使其立即生效..."
        /etc/init.d/kmod start &>/dev/null
        echo "模块配置已生效 ✅"
    else
        echo "未找到 /etc/init.d/kmod 跳过此步骤 ➡️"
    fi
    echo "设备传感器模块已配置完成!"
elif grep -q "No modules to load, skipping modules configuration" /tmp/sensors; then
    echo "未找到需要手动加载的模块, 跳过配置步骤 (可能已由内核自动加载) ➡️"
elif grep -q "Sorry, no sensors were detected" /tmp/sensors; then
    echo "未检测到任何传感器, 跳过配置步骤 (当前环境可能为虚拟机) ⚠️"
else
    echo "发生预期外的错误, 跳过配置步骤! 你的设备可能不支持或内核未包含相关模块 ⛔"
fi

rm -f /tmp/sensors

# 确保 msr 模块被加载并设为开机自启, 为 turbostat 提供支持
modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf

echo && sleep 0.5

####################   配置 sudo 执行权限   ####################

echo -e "🔩 正在配置必要的执行权限:"
echo -e "允许 www-data 用户以 sudo 权限执行特定监控命令"
SUDOERS_FILE="/etc/sudoers.d/pve-manager-status"
# 首先移除可能被添加的 SUID 权限设置, 以防曾经被其它监控脚本添加
binaries=(/usr/sbin/nvme /usr/bin/iostat /usr/bin/sensors /usr/bin/cpupower /usr/sbin/smartctl /usr/sbin/turbostat)
for bin in "${binaries[@]}"; do
    if [[ -e $bin && -u $bin ]]; then
        chmod -s "$bin" && echo "检测到不安全的 SUID 权限已移除: $bin ⚠️"
    fi
done

# 定义需要 sudo 权限执行命令的绝对路径
SENSORS_PATH=$(command -v sensors)
TURBOSTAT_PATH=$(command -v turbostat)
SMARTCTL_PATH=$(command -v smartctl)
IOSTAT_PATH=$(command -v iostat)
SATA_PARSER_PATH="/usr/local/bin/pve_sata_parser.py"

# 配置 sudoers 规则内容
echo -e "正在配置 sudoers 规则内容并进行语法检查..."
read -r -d '' SUDOERS_CONTENT << EOM
# Allow www-data user (PVE Web GUI) to run specific hardware monitoring commands
# This file is managed by pve-manager-status.sh (https://github.com/MiKing233/PVE-Manager-Status)

Cmnd_Alias PVE_MANAGER_STATUS = ${SENSORS_PATH}, ${TURBOSTAT_PATH}, ${SMARTCTL_PATH}, ${IOSTAT_PATH}, ${SATA_PARSER_PATH}
Defaults!PVE_MANAGER_STATUS !log_allowed
Defaults!PVE_MANAGER_STATUS !pam_session

www-data ALL=(root) NOPASSWD: ${SENSORS_PATH}
www-data ALL=(root) NOPASSWD: ${TURBOSTAT_PATH} -S -q -s PkgWatt -i 0.1 -n 1 -c package
www-data ALL=(root) NOPASSWD: ${SMARTCTL_PATH} -a /dev/*
www-data ALL=(root) NOPASSWD: ${IOSTAT_PATH} -d -x -k 1 1
www-data ALL=(root) NOPASSWD: ${SATA_PARSER_PATH}

EOM

# 使用 visudo 在最终添加前对 sudoers 规则执行语法检查
TMP_SUDOERS=$(mktemp)
echo "${SUDOERS_CONTENT}" > "${TMP_SUDOERS}"

if visudo -c -f "${TMP_SUDOERS}" &> /dev/null; then
    echo "sudoers 规则语法检查通过 ✅"
    mv "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    echo "已成功配置 sudo 规则于: ${SUDOERS_FILE} 🔐"
else
    echo "⛔ sudoers 规则语法错误, 操作终止!"
    echo -e "\n--- DEBUG INFO START ---"
    echo "生成的 sudoers 规则内容如下:"
    echo "--------------------------------------------------"
    cat "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo
    echo "visudo 语法检查的详细错误信息:"
    echo "--------------------------------------------------"
    visudo -c -f "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo -e "\n--- DEBUG INFO END ---"
    rm -f "${TMP_SUDOERS}"
    echo && exit 1
fi

echo && sleep 0.5

####################   概要页面监控功能实现   ####################

echo -e "📋 正在添加概要页面监控功能:"

# 生成 SATA/SAS 直连盘 SMART 解析器
echo -e "\n💽 正在生成 SATA SMART 解析器: ${sata_parser_file}"
cat > "$sata_parser_file" << 'PVE_SATA_PARSER_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PVE SATA/SAS direct-attached disk SMART parser.

Output (one line per disk, disks separated by ||):
model|temp|hours|defects|health|uncorrected|serial|mfg|read_gb|write_gb|unsafe|life
"""

import fcntl
import glob
import os
import re
import shutil
import stat
import subprocess
import sys
import time

CACHE_DIR = os.environ.get("PVE_SATA_CACHE_DIR", "/var/cache/pve-manager")
CACHE_FILE = os.path.join(CACHE_DIR, "sata.cache")
LOCK_FILE = os.path.join(CACHE_DIR, "sata.lock")
TTL = max(5, int(os.environ.get("PVE_SATA_TTL", "300")))

SMARTCTL_DEFAULT = "/usr/sbin/smartctl"
SMARTCTL = os.environ.get("PVE_SATA_SMARTCTL") or (
    SMARTCTL_DEFAULT if os.path.exists(SMARTCTL_DEFAULT) else (shutil.which("smartctl") or SMARTCTL_DEFAULT)
)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

LIFE_ATTRIBUTES = (
    "Media_Wearout_Indicator",
    "Wear_Leveling_Count",
    "SSD_Life_Left",
    "Percent_Lifetime_Remain",
    "Remaining_Lifetime_Perc",
)


def _env():
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    env["LANG"] = "C"
    return env


def _run(args, timeout=15):
    try:
        proc = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_env(),
            timeout=timeout,
            check=False,
        )
        return proc.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""


def _smartctl(args, timeout=15):
    if os.geteuid() == 0:
        return _run([SMARTCTL] + args, timeout=timeout)
    return _run(["sudo", "-n", SMARTCTL] + args, timeout=timeout)


def _attr_raw(line):
    parts = line.split()
    return parts[9] if len(parts) >= 10 else ""


def _attr_value(line):
    parts = line.split()
    return parts[3] if len(parts) >= 10 else ""


def _leading_int(value):
    match = re.match(r"(\d+)", value or "")
    return int(match.group(1)) if match else None


def _clean(value, fallback="-"):
    value = str(value).replace("|", "/").replace("\r", " ").replace("\n", " ").strip()
    return value if value else fallback


def _lba_gb(value, is_ssd):
    # 大多数盘按 512 字节 LBA 上报；部分 SSD 固件把 Total_LBAs 按 32MiB 为单位上报
    if is_ssd and value < 1000000:
        return value * 32.0 * 1024.0 * 1024.0 / 1000000000.0
    return value * 512.0 / 1000000000.0


def parse_disk(text):
    model = "未知"
    temp = "-"
    hours = "-"
    defects = 0
    health = "OK"
    uncorrected = 0
    serial = "-"
    mfg = "-"
    read_gb = 0.0
    write_gb = 0.0
    unsafe = "-"
    life = "-"
    is_ssd = False
    pending = 0
    offline_unc = 0

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        if line.startswith("Product:"):
            model = line.split(":", 1)[1].strip()
        elif line.startswith("Device Model:"):
            model = line.split(":", 1)[1].strip()
        elif line.startswith("Serial number:") or line.startswith("Serial Number:"):
            serial = line.split(":", 1)[1].strip()
        elif line.startswith("Manufactured in week"):
            match = re.search(r"week\s+(\d+)\s+of\s+year\s+(\d+)", line, re.I)
            if match:
                mfg = "W{:02d} {}".format(int(match.group(1)), match.group(2))
        elif "Current Drive Temperature:" in line or line.startswith("Drive Temperature:"):
            match = re.search(r"(\d+)\s*C", line)
            if match:
                temp = match.group(1)
        elif line.startswith("Accumulated power on time"):
            match = re.search(r"(\d+):\d+", line)
            if match:
                hours = match.group(1)
        elif "Power_On_Hours" in line and hours == "-":
            value = _leading_int(_attr_raw(line))
            if value is not None:
                hours = str(value)
        elif "Elements in grown defect list:" in line:
            match = re.search(r":\s*(\d+)", line)
            if match:
                defects = int(match.group(1))
        elif "Reallocated_Sector_Ct" in line and defects == 0:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                defects = value
        elif "Current_Pending_Sector" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                pending = value
        elif "Offline_Uncorrectable" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                offline_unc = value
        elif line.startswith(("read:", "write:", "verify:")):
            parts = line.split()
            if len(parts) >= 8:
                try:
                    gb = float(parts[6])
                    unc = int(parts[7])
                except ValueError:
                    continue
                if line.startswith("read:"):
                    read_gb = gb
                elif line.startswith("write:"):
                    write_gb = gb
                uncorrected += max(0, unc)
        elif "Reported_Uncorrect" in line:
            value = _leading_int(_attr_raw(line))
            if value:
                uncorrected += value
        elif "Unsafe_Shutdown_Count" in line or "Power_Loss_Count" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                unsafe = value
        elif any(name in line for name in LIFE_ATTRIBUTES):
            value = _leading_int(_attr_value(line))
            if value is not None:
                life = value
        elif "Percentage used endurance indicator:" in line:
            match = re.search(r"(\d+)\s*%", line)
            if match:
                life = max(0, 100 - int(match.group(1)))
        elif (
            "Temperature_Celsius" in line
            or "Temperature_Case" in line
            or "Temperature_Internal" in line
            or "Airflow_Temperature_Cel" in line
        ):
            if temp == "-":
                match = re.match(r"(\d+)", _attr_raw(line))
                if match:
                    temp = match.group(1)
        elif "SMART Health Status:" in line:
            if "OK" not in line:
                health = "警告"
        elif "SMART overall-health self-assessment test result:" in line:
            if "PASSED" not in line:
                health = "警告"
        elif "Host_Reads_32MiB" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                read_gb = value * 32.0 / 1024.0
        elif "Host_Writes_32MiB" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                write_gb = value * 32.0 / 1024.0
        elif "Total_LBAs_Read" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                read_gb = _lba_gb(value, is_ssd)
        elif "Total_LBAs_Written" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                write_gb = _lba_gb(value, is_ssd)
        elif line.startswith("Rotation Rate:") and "Solid State" in line:
            is_ssd = True

    if model == "未知":
        return None

    # 真实的 SATA/SAS 盘至少应能读到温度或通电时间之一
    if temp == "-" and hours == "-":
        return None

    # 坏道汇总：重映射 + 待映射
    defects = max(defects, 0) + max(pending, 0)
    uncorrected = max(uncorrected, 0) + max(offline_unc, 0)

    if mfg == "-" and "INTEL" in model.upper():
        match = re.match(r"^[A-Z]{4}(\d)(\d{2})", serial.upper())
        if match:
            year = 2010 + int(match.group(1))
            week = int(match.group(2))
            if 1 <= week <= 53:
                mfg = "W{:02d} {}".format(week, year)

    if is_ssd and "(SSD)" not in model:
        model = model + " (SSD)"

    read_str = "{:.1f}".format(read_gb) if read_gb > 0 else "0"
    write_str = "{:.1f}".format(write_gb) if write_gb > 0 else "0"

    values = [
        _clean(model, "未知"),
        _clean(temp, "-"),
        _clean(hours, "-"),
        str(defects),
        _clean(health, "OK"),
        str(uncorrected),
        _clean(serial, "-"),
        _clean(mfg, "-"),
        read_str,
        write_str,
        _clean(unsafe, "-"),
        _clean(life, "-"),
    ]
    return "|".join(values)


def list_devices():
    devices = []
    for path in sorted(glob.glob("/dev/sd*")):
        if not re.match(r"^/dev/sd[a-z]+$", path):
            continue
        try:
            if not stat.S_ISBLK(os.stat(path).st_mode):
                continue
        except OSError:
            continue
        devices.append(path)
    return devices


def refresh():
    rows = []
    for dev in list_devices():
        output = _smartctl(["-a", dev], timeout=20)
        if "Device Model:" not in output and "Product:" not in output:
            fallback = _smartctl(["-a", "-d", "sat", dev], timeout=20)
            if fallback:
                output = fallback
        if not output:
            continue
        row = parse_disk(output)
        if row:
            rows.append(row)
    return "||".join(rows)


def _ensure_cache_files():
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        os.chmod(CACHE_DIR, 0o755)
    except OSError:
        pass


def read_cache(ignore_ttl=False):
    try:
        if not ignore_ttl and time.time() - os.path.getmtime(CACHE_FILE) > TTL:
            return None
        with open(CACHE_FILE, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return None


def write_cache(value):
    tmp_file = "{}.tmp.{}".format(CACHE_FILE, os.getpid())
    try:
        with open(tmp_file, "w", encoding="utf-8") as handle:
            handle.write(value)
        os.chmod(tmp_file, 0o644)
        os.replace(tmp_file, CACHE_FILE)
    except OSError:
        try:
            os.unlink(tmp_file)
        except OSError:
            pass


def main():
    cached = read_cache()
    if cached is not None:
        print(cached)
        return 0

    _ensure_cache_files()

    lock_handle = None
    try:
        lock_handle = open(LOCK_FILE, "a+")
        try:
            fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(read_cache(ignore_ttl=True) or "")
            return 0

        value = refresh()
        stale = read_cache(ignore_ttl=True)
        if value:
            write_cache(value)
            print(value)
        elif stale:
            # 本次读取失败时保留上一份有效数据，避免页面闪烁
            print(stale)
        else:
            # 不缓存空结果，下一次页面请求会重试
            print("")
        return 0
    except Exception:
        print(read_cache(ignore_ttl=True) or "")
        return 1
    finally:
        if lock_handle is not None:
            try:
                fcntl.flock(lock_handle, fcntl.LOCK_UN)
            except Exception:
                pass
            lock_handle.close()


if __name__ == "__main__":
    sys.exit(main())
PVE_SATA_PARSER_EOF

chmod 0755 "$sata_parser_file"
chown root:root "$sata_parser_file"
sed -i "s|^SMARTCTL_DEFAULT = .*|SMARTCTL_DEFAULT = \"${SMARTCTL_PATH}\"|" "$sata_parser_file"

install -d -m 0755 -o root -g root /var/cache/pve-manager

if ! python3 - "$sata_parser_file" << 'PYCHECK'
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    compile(handle.read(), sys.argv[1], "exec")
PYCHECK
then
    echo -e "⛔ SATA SMART 解析器语法检查失败"
    exit 1
fi
echo "SATA SMART 解析器已生成 ✅"

# 修改 node.pm 文件前置步骤
tmpf1=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf1" << 'EOF'

        my $cpumodes = `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`;
        my $cpupowers = `sudo turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package | grep -v PkgWatt`;
        $res->{cpupower} = $cpumodes . $cpupowers;

        my $cpufreqs = `lscpu | grep MHz`;
        my $threadfreqs = `cat /proc/cpuinfo | grep -i "cpu MHz"`;
        $res->{cpufreq} = $cpufreqs . $threadfreqs;

        $res->{sensors} = `sudo sensors`;
EOF

cat >> "$tmpf1" << 'EOF'

        # 集群同构：无论本机是否存在 NVMe，都生成 nvme0..nvme9 的读取代码。
        # 运行时用 Perl 的 -b 判断设备路径，避免对不存在的设备调用 smartctl。
        my $iostat_all = `sudo iostat -d -x -k 1 1`;
        for my $x (0..9) {
            my $nvme_dev = "";
            if (-b "/dev/nvme${x}n1") {
                $nvme_dev = "/dev/nvme${x}n1";
            } elsif (-b "/dev/nvme$x") {
                $nvme_dev = "/dev/nvme$x";
            }

            my $nvme_info = "";
            if ($nvme_dev) {
                $nvme_info = `sudo smartctl -a $nvme_dev 2>/dev/null | grep -E "Model Number|Serial Number|Firmware Version|NVMe Version|(?=Total|Namespace)[^:]+Capacity|Temperature:|Available Spare:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors"`;
            }

            # 读取 PCIe 链路速率/宽度（sysfs，www-data 可读）
            my $nvme_pcie = "";
            my $speed = "";
            my $width = "";
            if (open my $speed_fh, '<', "/sys/class/nvme/nvme${x}/device/current_link_speed") {
                $speed = <$speed_fh>;
                close $speed_fh;
                chomp $speed;
            }
            if (open my $width_fh, '<', "/sys/class/nvme/nvme${x}/device/current_link_width") {
                $width = <$width_fh>;
                close $width_fh;
                chomp $width;
            }
            if ($speed ne "" && $width ne "") {
                $nvme_pcie = "PCIe Link: $speed x$width\n";
            }

            my @nvme_io = grep { /^nvme${x}/ } split /\n/, $iostat_all;
            $res->{"nvme${x}_status"} = $nvme_info . $nvme_pcie . join("\n", @nvme_io);
        }
EOF

cat >> "$tmpf1" << 'EOF'

        $res->{sata_status} = `sudo /usr/local/bin/pve_sata_parser.py`;
EOF

# 在实际修改前检查锚点文本是否存在, 若不存在则报错退出停止修改
if ! grep -q 'PVE::pvecfg::version_text' "$nodes"; then
    echo "⛔ 在 $nodes 中未找到锚点, 操作终止!"
    rm -f "$tmpf1"
    echo -e "⚠️ 锚点'PVE::pvecfg::version_text', 文件可能已更新或与当前版本不兼容"
    echo && exit 1
fi

# 应用更改
sed -i '/PVE::pvecfg::version_text/ r '"$tmpf1"'' "$nodes"

# 验证修改是否成功
if grep -q 'cpupower' "$nodes"; then
    echo "已完成修改: $nodes ✅"
else
    echo "⛔ 检查对 $nodes 添加的内容未生效!"
    rm -f "$tmpf1"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容"
    echo && exit 1
fi

rm -f "$tmpf1"

# 修改 pvemanagerlib.js 文件前置步骤
tmpf2=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf2" << 'EOF'
        {
            itemId: 'cpupower',
            colspan: 2,
            printBar: false,
            title: gettext('CPU能耗'),
            textField: 'cpupower',
            renderer:function(value){
                function colorizeCpuMode(mode) {
                    if (mode === 'powersave') return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${mode}</span>`;
                    if (mode === 'performance') return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${mode}</span>`;
                    return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${mode}</span>`;
                }
                function colorizeCpuPower(power) {
                    const powerNum = parseFloat(power);
                    if (powerNum < 20) return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${power} W</span>`;
                    if (powerNum < 50) return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${power} W</span>`;
                    return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${power} W</span>`;
                }
                const w0 = value.split('\n')[0].split(' ')[0];
                const w1 = value.split('\n')[1].split(' ')[0];
                return `CPU电源模式: ${colorizeCpuMode(w0)} | CPU功耗: ${colorizeCpuPower(w1)}`
            }
        },
        {
            itemId: 'cpufreq',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率'),
            textField: 'cpufreq',
            renderer:function(value){
                function colorizeCpuFreq(freq) {
                    const freqNum = parseFloat(freq);
                    if (freqNum < 1500) return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${freq} MHz</span>`;
                    if (freqNum < 3000) return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${freq} MHz</span>`;
                    return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${freq} MHz</span>`;
                }
                const f0 = value.match(/cpu MHz.*?([\d]+)/)[1];
                const f1 = value.match(/CPU min MHz.*?([\d]+)/)[1];
                const f2 = value.match(/CPU max MHz.*?([\d]+)/)[1];
                return `CPU实时: ${colorizeCpuFreq(f0)} | 最小: ${f1} MHz | 最大: ${f2} MHz `
            }
        },
        {
            itemId: 'sensors',
            colspan: 2,
            printBar: false,
            title: gettext('传感器'),
            textField: 'sensors',
            renderer: function(value) {
                function colorizeCpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeGpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeAcpiTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeFanRpm(rpm) {
                    const rpmNum = parseFloat(rpm);
                    if (rpmNum < 1500) return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${rpm}转/分钟</span>`;
                    if (rpmNum < 3000) return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${rpm}转/分钟</span>`;
                    return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${rpm}转/分钟</span>`;
                }
                value = value.replace(/Â/g, '');
                let data = [];
                let cpus = value.matchAll(/^(?:coretemp-isa|k10temp-pci)-(\w{4})$\n.*?\n((?:Package|Core|Tctl)[\s\S]*?^\n)+/gm);
                for (const cpu of cpus) {
                    let cpuNumber = parseInt(cpu[1], 10);
                    data[cpuNumber] = {
                        packages: [],
                        cores: []
                    };

                    let packages = cpu[2].matchAll(/^(?:Package id \d+|Tctl):\s*\+([^°C ]+).*$/gm);
                    for (const package of packages) {
                        data[cpuNumber]['packages'].push(package[1]);
                    }
                    let cores = cpu[2].matchAll(/^Core (\d+):\s*\+([^°C ]+).*$/gm);
                    for (const core of cores) {
                        var corecombi = `核心 ${core[1]}: ${colorizeCpuTemp(core[2])}`
                        data[cpuNumber]['cores'].push(corecombi);
                    }
                }

                let output = '';
                for (const [i, cpu] of data.entries()) {
                    if (cpu.packages.length > 0) {
                        for (const packageTemp of cpu.packages) {
                            output += `CPU ${i}: ${colorizeCpuTemp(packageTemp)} | `;
                        }
                    }

                    let gpus = value.matchAll(/^amdgpu-pci-(\w*)$\n((?!edge:)[ \S]*?\n)*((?:edge)[\s\S]*?^\n)+/gm);
                    for (const gpu of gpus) {
                        let gpuNumber = 0;
                        data[gpuNumber] = {
                            edges: []
                        };

                        let edges = gpu[3].matchAll(/^edge:\s*\+([^°C ]+).*$/gm);
                        for (const edge of edges) {
                            data[gpuNumber]['edges'].push(edge[1]);
                        }

                        for (const [k, gpu] of data.entries()) {
                            if (gpu.edges.length > 0) {
                                output += '核显: ';
                                for (const edgeTemp of gpu.edges) {
                                    output += `${colorizeGpuTemp(edgeTemp)}, `;
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }

                    let acpitzs = value.matchAll(/^acpitz-acpi-(\d*)$\n.*?\n((?:temp)[\s\S]*?^\n)+/gm);
                    for (const acpitz of acpitzs) {
                        let acpitzNumber = parseInt(acpitz[1], 10);
                        data[acpitzNumber] = {
                            acpisensors: []
                        };

                        let acpisensors = acpitz[2].matchAll(/^temp\d+:\s*\+([^°C ]+).*$/gm);
                        for (const acpisensor of acpisensors) {
                            data[acpitzNumber]['acpisensors'].push(acpisensor[1]);
                        }

                        for (const [k, acpitz] of data.entries()) {
                            if (acpitz.acpisensors.length > 0) {
                                output += '主板: ';
                                for (const acpiTemp of acpitz.acpisensors) {
                                    output += `${colorizeAcpiTemp(acpiTemp)}, `;
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }

                    let FunStates = value.matchAll(/^(?:[a-zA-z]{2,3}\d{4}|dell_smm)-isa-(\w{4})$\n((?![ \S]+: *\d+ +RPM)[ \S]*?\n)*((?:[ \S]+: *\d+ RPM)[\s\S]*?^\n)+/gm);
                    for (const FunState of FunStates) {
                        let FanNumber = 0;
                        data[FanNumber] = {
                            rotationals: [],
                            cpufans: [],
                            motherboardfans: [],
                            pumpfans: [],
                            systemfans: []
                        };

                        let rotationals = FunState[3].match(/^([ \S]+: *[0-9]\d* +RPM)[ \S]*?$/gm);
                        for (const rotational of rotationals) {
                            if (rotational.toLowerCase().indexOf("pump") !== -1 || rotational.toLowerCase().indexOf("opt") !== -1){
                                let pumpfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const pumpfan of pumpfans) {
                                    data[FanNumber]['pumpfans'].push(pumpfan[1]);
                                }
                            } else if (rotational.toLowerCase().indexOf("cpu") !== -1 || rotational.toLowerCase().indexOf("processor") !== -1){
                                let cpufans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const cpufan of cpufans) {
                                    data[FanNumber]['cpufans'].push(cpufan[1]);
                                }
                            } else if (rotational.toLowerCase().indexOf("motherboard") !== -1){
                                let motherboardfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const motherboardfan of motherboardfans) {
                                    data[FanNumber]['motherboardfans'].push(motherboardfan[1]);
                                }
                            }  else {
                                let systemfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const systemfan of systemfans) {
                                    data[FanNumber]['systemfans'].push(systemfan[1]);
                                }
                            }
                        }

                        for (const [j, FunState] of data.entries()) {
                            if (FunState.cpufans.length > 0 || FunState.motherboardfans.length > 0 || FunState.pumpfans.length > 0 || FunState.systemfans.length > 0) {
                                output += '风扇: ';
                                if (FunState.cpufans.length > 0) {
                                    output += 'CPU-';
                                    for (const cpufan_value of FunState.cpufans) {
                                        output += `${colorizeFanRpm(cpufan_value)}, `;
                                    }
                                }

                                if (FunState.motherboardfans.length > 0) {
                                    output += '主板-';
                                    for (const motherboardfan_value of FunState.motherboardfans) {
                                        output += `${colorizeFanRpm(motherboardfan_value)}, `;
                                    }
                                }

                                if (FunState.pumpfans.length > 0) {
                                    output += '水冷-';
                                    for (const pumpfan_value of FunState.pumpfans) {
                                        output += `${colorizeFanRpm(pumpfan_value)}, `;
                                    }
                                }

                                if (FunState.systemfans.length > 0) {
                                    if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0) {
                                        output += '系统-';
                                    }
                                    for (const systemfan_value of FunState.systemfans) {
                                        output += `${colorizeFanRpm(systemfan_value)}, `;
                                    }
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else if (FunState.cpufans.length == 0 && FunState.pumpfans.length == 0 && FunState.systemfans.length == 0) {
                                output += ' 风扇: 停转';
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }
                    output = output.slice(0, -2);

                    if (cpu.cores.length > 1) {
                        output += '\n';
                        for (j = 1;j < cpu.cores.length;) {
                            for (const coreTemp of cpu.cores) {
                                output += `${coreTemp} | `;
                                j++;
                                if ((j-1) % 4 == 0){
                                    output = output.slice(0, -2);
                                    output += '\n';
                                }
                            }
                        }
                        output = output.slice(0, -2);
                    }
                    output += '\n';
                }

                output = output.slice(0, -2);
                return output.replace(/\n/g, '<br>');
            }
        },
        {
            itemId: 'corefreq',
            colspan: 2,
            printBar: false,
            title: gettext('核心频率'),
            textField: 'cpufreq',
            renderer: function(value) {
                function colorizeCpuFreq(freq) {
                    const freqNum = parseFloat(freq);
                    if (freqNum < 1500) return `<span style="color:var(--pve-manager-status-low); font-weight:bold;">${freq} MHz</span>`;
                    if (freqNum < 3000) return `<span style="color:var(--pve-manager-status-medium); font-weight:bold;">${freq} MHz</span>`;
                    return `<span style="color:var(--pve-manager-status-high); font-weight:bold;">${freq} MHz</span>`;
                }
                const freqMatches = value.matchAll(/^cpu MHz\s*:\s*([\d\.]+)/gm);
                const frequencies = [];

                for (const match of freqMatches) {
                    const coreNum = frequencies.length + 1;
                    frequencies.push(`线程 ${coreNum}: ${colorizeCpuFreq(parseInt(match[1]))}`);
                }

                if (frequencies.length === 0) {
                    return '无法获取CPU频率信息';
                }

                const groupedFreqs = [];
                for (let i = 0; i < frequencies.length; i += 4) {
                    const group = frequencies.slice(i, i + 4);
                    groupedFreqs.push(group.join(' | '));
                }

                return groupedFreqs.join('<br>');
            }
        },
EOF

for x in {0..9}; do
    cat >> "$tmpf2" << EOF
        {
            itemId: 'nvme${x}-status',
            colspan: 2,
            printBar: false,
            title: gettext('NVMe${x}硬盘'),
            textField: 'nvme${x}_status',
            renderer:function(value){
                var field = this;
                var isNvmeField = field && field.itemId === 'nvme${x}-status';
                var hasData = value && String(value).trim() !== '';
                try {
                    if (isNvmeField && field.setHidden) {
                        field.setHidden(!hasData);
                    } else if (isNvmeField && field.setVisible) {
                        field.setVisible(hasData);
                    }
                } catch (e) {}
                function getSsdLifeColor(life) {
                    const lifeNum = parseFloat(life);
                    if (lifeNum < 50) return 'var(--pve-manager-status-high)';
                    if (lifeNum < 80) return 'var(--pve-manager-status-medium)';
                    return 'var(--pve-manager-status-low)';
                }
                function colorizeSsdModel(model, life) {
                    const color = getSsdLifeColor(life);
                    return \`型号: <span style="color:\${color}; font-weight:bold;">\${model}</span>\`;
                }
                function colorizeSsdLife(life) {
                    const color = getSsdLifeColor(life);
                    return \`<span style="color:\${color}; font-weight:bold;">\${life}%</span>\`;
                }
                function colorizeSsdTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 50) return \`<span style="color:var(--pve-manager-status-low); font-weight:bold;">\${temp}°C</span>\`;
                    if (tempNum < 70) return \`<span style="color:var(--pve-manager-status-medium); font-weight:bold;">\${temp}°C</span>\`;
                    return \`<span style="color:var(--pve-manager-status-high); font-weight:bold;">\${temp}°C</span>\`;
                }
                function colorizeSsdLoad(load) {
                    const loadNum = parseFloat(load);
                    if (loadNum < 50) return \`<span style="color:var(--pve-manager-status-low); font-weight:bold;">\${load}%</span>\`;
                    if (loadNum < 80) return \`<span style="color:var(--pve-manager-status-medium); font-weight:bold;">\${load}%</span>\`;
                    return \`<span style="color:var(--pve-manager-status-high); font-weight:bold;">\${load}%</span>\`;
                }
                function colorizeIoSpeed(speed) {
                    const speedNum = parseFloat(speed);
                    if (speedNum > 1000) return \`<span style="color:var(--pve-manager-status-high); font-weight:bold;">\${speed}MB/s</span>\`;
                    if (speedNum < 100) return \`<span style="color:var(--pve-manager-status-low); font-weight:bold;">\${speed}MB/s</span>\`;
                    return \`<span style="color:var(--pve-manager-status-medium); font-weight:bold;">\${speed}MB/s</span>\`;
                }
                function colorizeIoLatency(latency) {
                    const latencyNum = parseFloat(latency);
                    if (latencyNum > 10) return \`<span style="color:var(--pve-manager-status-high); font-weight:bold;">\${latency}ms</span>\`;
                    if (latencyNum < 1) return \`<span style="color:var(--pve-manager-status-low); font-weight:bold;">\${latency}ms</span>\`;
                    return \`<span style="color:var(--pve-manager-status-medium); font-weight:bold;">\${latency}ms</span>\`;
                }
                if (hasData) {
                    value = value.replace(/Â/g, '');
                    let data = [];
                    let nvmeNumber = -1;

                    let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Available Spare:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
                    
                    for (const nvme of nvmes) {
                        if (/Model Number:/.test(nvme[1])) {
                            nvmeNumber++; 
                            data[nvmeNumber] = {
                                Models: [],
                                PCIe_Links: [],
                                NVMe_Versions: [],
                                Serials: [],
                                Firmwares: [],
                                Integrity_Errors: [],
                                Capacitys: [],
                                Temperatures: [],
                                Available_Spares: [],
                                Useds: [],
                                Reads: [],
                                Writtens: [],
                                Cycles: [],
                                Hours: [],
                                Shutdowns: [],
                                States: [],
                                r_kBs: [],
                                r_awaits: [],
                                w_kBs: [],
                                w_awaits: [],
                                utils: []
                            };
                        }

                        if (nvmeNumber === -1) continue;

                        let Models = nvme[1].matchAll(/^Model Number: *([ \S]*)$/gm);
                        for (const Model of Models) {
                            data[nvmeNumber]['Models'].push(Model[1]);
                        }

                        let PCIe_Links = nvme[1].matchAll(/^PCIe Link: *(.*)$/gm);
                        for (const PCIe_Link of PCIe_Links) {
                            data[nvmeNumber]['PCIe_Links'].push(PCIe_Link[1].trim());
                        }

                        let NVMe_Versions = nvme[1].matchAll(/^NVMe Version: *(.*)$/gm);
                        for (const NVMe_Version of NVMe_Versions) {
                            data[nvmeNumber]['NVMe_Versions'].push(NVMe_Version[1].trim());
                        }

                        let Serials = nvme[1].matchAll(/^Serial Number: *(.*)$/gm);
                        for (const Serial of Serials) {
                            data[nvmeNumber]['Serials'].push(Serial[1].trim());
                        }

                        let Firmwares = nvme[1].matchAll(/^Firmware Version: *(.*)$/gm);
                        for (const Firmware of Firmwares) {
                            data[nvmeNumber]['Firmwares'].push(Firmware[1].trim());
                        }

                        let Integrity_Errors = nvme[1].matchAll(/^Media and Data Integrity Errors: *([ \S]*)$/gm);
                        for (const Integrity_Error of Integrity_Errors) {
                            data[nvmeNumber]['Integrity_Errors'].push(Integrity_Error[1]);
                        }

                        let Capacitys = nvme[1].matchAll(/^(?=Total|Namespace)[^:]+Capacity:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Capacity of Capacitys) {
                            data[nvmeNumber]['Capacitys'].push(Capacity[1]);
                        }

                        let Temperatures = nvme[1].matchAll(/^Temperature: *([\d]*)[ \S]*$/gm);
                        for (const Temperature of Temperatures) {
                            data[nvmeNumber]['Temperatures'].push(Temperature[1]);
                        }

                        let Available_Spares = nvme[1].matchAll(/^Available Spare: *([\d]*%)[ \S]*$/gm);
                        for (const Available_Spare of Available_Spares) {
                            data[nvmeNumber]['Available_Spares'].push(Available_Spare[1]);
                        }

                        let Useds = nvme[1].matchAll(/^Percentage Used: *([ \S]*)%$/gm);
                        for (const Used of Useds) {
                            data[nvmeNumber]['Useds'].push(Used[1]);
                        }

                        let Reads = nvme[1].matchAll(/^Data Units Read:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Read of Reads) {
                            data[nvmeNumber]['Reads'].push(Read[1]);
                        }

                        let Writtens = nvme[1].matchAll(/^Data Units Written:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Written of Writtens) {
                            data[nvmeNumber]['Writtens'].push(Written[1]);
                        }

                        let Cycles = nvme[1].matchAll(/^Power Cycles: *([ \S]*)$/gm);
                        for (const Cycle of Cycles) {
                            data[nvmeNumber]['Cycles'].push(Cycle[1]);
                        }

                        let Hours = nvme[1].matchAll(/^Power On Hours: *([ \S]*)$/gm);
                        for (const Hour of Hours) {
                            data[nvmeNumber]['Hours'].push(Hour[1]);
                        }

                        let Shutdowns = nvme[1].matchAll(/^Unsafe Shutdowns: *([ \S]*)$/gm);
                        for (const Shutdown of Shutdowns) {
                            data[nvmeNumber]['Shutdowns'].push(Shutdown[1]);
                        }

                        let States = nvme[1].matchAll(/^nvme\S+(( *\d+\.\d{2}){22})/gm);
                        for (const State of States) {
                            data[nvmeNumber]['States'].push(State[1]);
                            const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
                            if (IO_array.length > 0) {
                                data[nvmeNumber]['r_kBs'].push(IO_array[1]);
                                data[nvmeNumber]['r_awaits'].push(IO_array[4]);
                                data[nvmeNumber]['w_kBs'].push(IO_array[7]);
                                data[nvmeNumber]['w_awaits'].push(IO_array[10]);
                                data[nvmeNumber]['utils'].push(IO_array[21]);
                            }
                        }
                    }

                    let output = '';
                    for (const [i, nvme] of data.entries()) {
                        if (i > 0) output += '<br><br>';
                        const appendLine = (text) => {
                            if (!text) return;
                            if (!output.endsWith('<br>')) output += '<br>';
                            output += text;
                        };

                        if (nvme.Models.length > 0) {
                            output += colorizeSsdModel(nvme.Models[0], 100 - Number(nvme.Useds[0]));

                            if (nvme.Integrity_Errors.length > 0) {
                                for (const nvmeIntegrity_Error of nvme.Integrity_Errors) {
                                    if (nvmeIntegrity_Error != 0) {
                                        output += ' (';
                                        output += \`0E: \${nvmeIntegrity_Error}-故障！\`;
                                        if (nvme.Available_Spares.length > 0) {
                                            output += ', ';
                                            for (const Available_Spare of nvme.Available_Spares) {
                                                output += \`备用空间: \${Available_Spare}\`;
                                            }
                                        }
                                        output += ')';
                                    }
                                }
                            }
                        }

                        if (nvme.Capacitys.length > 0) {
                            output += ' | ';
                            for (const nvmeCapacity of nvme.Capacitys) {
                                output += \`容量: \${nvmeCapacity.replace(/ |,/gm, '')}\`;
                            }
                        }
                        output += '<br>';

                        if (nvme.Useds.length > 0) {
                            for (const nvmeUsed of nvme.Useds) {
                                output += \`寿命: \${colorizeSsdLife(100-Number(nvmeUsed))} \`;
                                if (nvme.Reads.length > 0) {
                                    output += '(';
                                    for (const nvmeRead of nvme.Reads) {
                                        output += \`已读 \${nvmeRead.replace(/ |,/gm, '')}\`;
                                        output += ')';
                                    }
                                }

                                if (nvme.Writtens.length > 0) {
                                    output = output.slice(0, -1);
                                    output += ', ';
                                    for (const nvmeWritten of nvme.Writtens) {
                                        output += \`已写 \${nvmeWritten.replace(/ |,/gm, '')}\`;
                                    }
                                    output += ')';
                                }
                            }
                        }

                        if (nvme.Temperatures.length > 0) {
                            output += ' | ';
                            for (const nvmeTemperature of nvme.Temperatures) {
                                output += \`温度: \${colorizeSsdTemp(nvmeTemperature)}\`;
                            }
                        }

                        if (nvme.utils.length > 0) {
                            output += ' | ';
                            for (const nvme_util of nvme.utils) {
                                output += \`负载: \${colorizeSsdLoad(nvme_util)}\`;
                            }
                        }
                        output += '<br>';

                        if (nvme.States.length > 0) {
                            output += 'I/O: ';
                            if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
                                output += '读-';
                                if (nvme.r_kBs.length > 0) {
                                    for (const nvme_r_kB of nvme.r_kBs) {
                                        var nvme_r_mB = \`\${nvme_r_kB}\` / 1024;
                                        nvme_r_mB = nvme_r_mB.toFixed(2);
                                        output += \`速度 \${colorizeIoSpeed(nvme_r_mB)}\`;
                                    }
                                }
                                if (nvme.r_awaits.length > 0) {
                                    output += ', ';
                                    for (const nvme_r_await of nvme.r_awaits) {
                                        output += \`延迟 \${colorizeIoLatency(nvme_r_await)}\`;
                                    }
                                }
                            }

                            if (nvme.w_kBs.length > 0 || nvme.w_awaits.length > 0) {
                                if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
                                    output += ' / ';
                                }
                                output += '写-';
                                if (nvme.w_kBs.length > 0) {
                                    for (const nvme_w_kB of nvme.w_kBs) {
                                        var nvme_w_mB = \`\${nvme_w_kB}\` / 1024;
                                        nvme_w_mB = nvme_w_mB.toFixed(2);
                                        output += \`速度 \${colorizeIoSpeed(nvme_w_mB)}\`;
                                    }
                                }
                                if (nvme.w_awaits.length > 0) {
                                    output += ', ';
                                    for (const nvme_w_await of nvme.w_awaits) {
                                        output += \`延迟 \${colorizeIoLatency(nvme_w_await)}\`;
                                    }
                                }
                            }
                        }

                        const powerInfo = [];
                        if (nvme.Cycles.length > 0) {
                            powerInfo.push(\`通电: \${nvme.Cycles[0].replace(/ |,/gm, '')}次\`);
                        }
                        if (nvme.Shutdowns.length > 0) {
                            powerInfo.push(\`不安全断电: \${nvme.Shutdowns[0].replace(/ |,/gm, '')}次\`);
                        }
                        if (nvme.Hours.length > 0) {
                            powerInfo.push(\`累计: \${nvme.Hours[0].replace(/ |,/gm, '')}小时\`);
                        }
                        if (powerInfo.length > 0) {
                            appendLine(powerInfo.join(' | '));
                        }

                        const identityInfo = [];
                        if (nvme.Serials.length > 0) {
                            identityInfo.push(\`序列号: \${nvme.Serials[0]}\`);
                        }
                        if (nvme.Firmwares.length > 0) {
                            identityInfo.push(\`固件版本: \${nvme.Firmwares[0]}\`);
                        }
                        if (identityInfo.length > 0) {
                            appendLine(identityInfo.join(' | '));
                        }

                        const linkInfo = [];
                        if (nvme.NVMe_Versions.length > 0) {
                            linkInfo.push(\`NVMe版本: \${nvme.NVMe_Versions[0]}\`);
                        }
                        if (nvme.PCIe_Links.length > 0) {
                            const pcie = nvme.PCIe_Links[0];
                            const match = pcie.match(/^([\d.]+) GT\/s PCIe x(\d+)$/);
                            const generations = {'2.5': '1.0', '5': '2.0', '8': '3.0', '16': '4.0', '32': '5.0', '64': '6.0'};
                            const gen = match ? generations[parseFloat(match[1])] : null;
                            linkInfo.push(gen ? \`连接速率: PCIe \${gen} x\${match[2]}\` : \`连接速率: \${pcie}\`);
                        }
                        if (linkInfo.length > 0) {
                            appendLine(linkInfo.join(' | '));
                        }
                    }
                    return output;

                } else {
                    return '';
                }
            },
        },
EOF
done

cat >> "$tmpf2" << 'EOF'
        {
            itemId: 'sata_status',
            colspan: 2,
            printBar: false,
            title: gettext('SATA硬盘'),
            textField: 'sata_status',
            renderer: function(value) {
                if (!value || String(value).trim() === '') {
                    return '提示: 未检测到 SATA 硬盘';
                }
                function esc(v) {
                    return String(v === undefined || v === null ? '' : v).replace(/[&<>"']/g, function(c) {
                        return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c];
                    });
                }
                function formatSize(gbStr) {
                    var gb = parseFloat(gbStr);
                    if (isNaN(gb) || gb <= 0) return '0 GB';
                    if (gb >= 1048576) return (gb / 1048576).toFixed(2) + ' PB';
                    if (gb >= 1024) return (gb / 1024).toFixed(2) + ' TB';
                    if (gb < 1) return (gb * 1024).toFixed(1) + ' MB';
                    return gb.toFixed(1) + ' GB';
                }
                function colorizeTemp(temp) {
                    var t = parseInt(temp, 10);
                    if (isNaN(t)) return esc(temp);
                    if (t < 50) return '<span style="color:var(--pve-manager-status-low, #008000); font-weight:bold;">' + t + '°C</span>';
                    if (t < 70) return '<span style="color:var(--pve-manager-status-medium, #ffa500); font-weight:bold;">' + t + '°C</span>';
                    return '<span style="color:var(--pve-manager-status-high, #ff0000); font-weight:bold;">' + t + '°C</span>';
                }
                function colorizeNum(num, isError) {
                    var n = parseInt(num, 10);
                    if (isNaN(n)) return esc(num);
                    if (n === 0) return '<span style="color:var(--pve-manager-status-low, #008000);">0</span>';
                    var color = isError ? 'var(--pve-manager-status-high, #ff0000)' : 'var(--pve-manager-status-medium, #ffa500)';
                    return '<span style="color:' + color + '; font-weight:bold;">' + n + '</span>';
                }
                function colorizeLife(life) {
                    var n = parseInt(life, 10);
                    if (isNaN(n)) return esc(life);
                    var color = n >= 80 ? 'var(--pve-manager-status-low, #008000)' :
                                (n >= 50 ? 'var(--pve-manager-status-medium, #ffa500)' : 'var(--pve-manager-status-high, #ff0000)');
                    return '<span style="color:' + color + '; font-weight:bold;">' + n + '%</span>';
                }
                function colorizeUnsafe(count) {
                    var n = parseInt(count, 10);
                    if (isNaN(n)) return esc(count);
                    return n + '次';
                }
                var disks = String(value).split('||').filter(function(x) { return x.trim() !== ''; });
                var output = [];
                for (var i = 0; i < disks.length; i++) {
                    var d = disks[i].trim().split('|');
                    if (d.length < 10) {
                        output.push(esc(disks[i]));
                        continue;
                    }
                    var model = d[0], temp = d[1], hour = d[2], defects = d[3], health = d[4];
                    var uncorrected = d[5], serial = d[6], mfg = d[7], readgb = d[8], writegb = d[9];
                    var unsafe = d.length > 10 ? d[10] : '-';
                    var life = d.length > 11 ? d[11] : '-';
                    var hours = parseInt(hour, 10);
                    var years = isNaN(hours) ? '-' : (hours / 8760).toFixed(1);
                    var lifeNum = parseInt(life, 10);
                    var modelColor = !isNaN(lifeNum) ?
                        (lifeNum >= 80 ? 'var(--pve-manager-status-low, #008000)' :
                         (lifeNum >= 50 ? 'var(--pve-manager-status-medium, #ffa500)' : 'var(--pve-manager-status-high, #ff0000)')) :
                        (health === 'OK' ? 'var(--pve-manager-status-low, #008000)' : 'var(--pve-manager-status-high, #ff0000)');
                    var healthColor = health === 'OK' ? 'var(--pve-manager-status-low, #008000)' : 'var(--pve-manager-status-high, #ff0000)';
                    var line1 = '<span style="color:' + modelColor + '; font-weight:bold;">' + esc(model) + '</span>' +
                                ' | 温度: ' + colorizeTemp(temp) +
                                ' | 通电: ' + (isNaN(hours) ? esc(hour) : hours + 'h (' + years + '年)') +
                                ' | 状态: <span style="color:' + healthColor + '; font-weight:bold;">' + esc(health) + '</span>';
                    var line2 = 'SN: ' + esc(serial) +
                                ' | 生产: ' + esc(mfg) +
                                ' | 坏道: ' + colorizeNum(defects, false) +
                                ' | 无法纠错: ' + colorizeNum(uncorrected, true);
                    var line3Parts = [];
                    if (!isNaN(lifeNum)) line3Parts.push('寿命: ' + colorizeLife(life));
                    if (!isNaN(parseInt(unsafe, 10))) line3Parts.push('不安全断电: ' + colorizeUnsafe(unsafe));
                    line3Parts.push('已读: ' + formatSize(readgb));
                    line3Parts.push('已写: ' + formatSize(writegb));
                    output.push(line1 + '<br>' + line2 + '<br>' + line3Parts.join(' | '));
                }
                return output.join('<br>');
            }
        },
EOF


# 计算插入行号
ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' $pvemanagerlib)

# 在实际修改前检查行号是否有效, 若无效则报错退出停止修改
if ! [[ "$ln" =~ ^[0-9]+$ ]]; then
    echo "⛔ 在 $pvemanagerlib 中计算插入位置失败, 操作终止!"
    rm -f "$tmpf2"
    echo -e "⚠️ 锚点'pveversion', 文件可能已更新或与当前版本不兼容"
    echo && exit 1
fi

# 应用更改
sed -i "${ln}r $tmpf2" "$pvemanagerlib"

# 支援跟隨 PVE 當前主題切换配色
cat >> "$pvemanagerlib" << 'EOF'

;(() => {
    const style = document.createElement('style');
    style.id = 'pve-manager-status-colors';
    // Light theme
    style.textContent = `
        :root {
            --pve-manager-status-low: #008000;
            --pve-manager-status-medium: #ffa500;
            --pve-manager-status-high: #ff0000;
        }
    `;
    // Proxmox Dark
    const darkTheme = document.querySelector('link[rel="stylesheet"][href*="/theme-proxmox-dark.css"]');
    if (darkTheme && !darkTheme.disabled) {
        const darkColors = `
            :root {
                --pve-manager-status-low: #3A7D6A;
                --pve-manager-status-medium: #C28B2C;
                --pve-manager-status-high: #C45B5B;
            }
        `;
        style.textContent += darkTheme.media
            ? `@media ${darkTheme.media} { ${darkColors} }`
            : darkColors;
    }
    document.head.appendChild(style);
})();
EOF

# 节点概要自动高度（集群共享前端，按当前节点实际内容调整）
cat >> "$pvemanagerlib" << 'EOF'

// === PVE-Manager-Status: 集群节点概要自动高度 (experimental) ===
;(() => {
    const STORAGE_KEY = 'pve-manager-status-auto-height';
    const PANEL_ID_PREFIX = 'pveNodeStatus-';
    const DEBUG = (() => {
        try {
            return localStorage.getItem('pve-manager-status-auto-height-debug') === '1';
        } catch (e) {
            return false;
        }
    })();

    function isDisabled() {
        try {
            return localStorage.getItem(STORAGE_KEY) === '0';
        } catch (e) {
            return false;
        }
    }

    function log(...args) {
        if (DEBUG) console.debug('[pve-manager-status height]', ...args);
    }

    function findContentTable(panelEl) {
        const body = panelEl.querySelector('.x-panel-body') || panelEl;
        const preferred = body.querySelectorAll('table.x-table-layout, table.x-table-layout-ct');
        const candidates = preferred.length ? preferred : body.querySelectorAll('table');
        let best = null;
        let bestHeight = 0;
        for (const table of candidates) {
            const height = table.offsetHeight || 0;
            if (height > bestHeight) {
                bestHeight = height;
                best = table;
            }
        }
        return best;
    }

    function measure(view) {
        if (!view || !view.el || !view.el.dom) return;
        const panelEl = view.el.dom;
        const table = findContentTable(panelEl);
        if (!table) return;
        const tableHeight = table.offsetHeight || 0;
        if (tableHeight < 40) return;

        const header = panelEl.querySelector('.x-panel-header');
        const headerHeight = header ? (header.offsetHeight || 0) : 0;
        const body = panelEl.querySelector('.x-panel-body');
        let padding = 0;
        if (body) {
            const style = window.getComputedStyle(body);
            padding = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
        }

        const needed = Math.ceil(tableHeight + headerHeight + padding + 4);
        const current = view.getHeight ? view.getHeight() : (panelEl.offsetHeight || 0);
        if (current && Math.abs(current - needed) <= 2) return;

        log('resize', { current, needed, tableHeight, headerHeight, padding });
        try {
            if (view.setHeight) {
                view.setHeight(needed);
            } else {
                panelEl.style.height = needed + 'px';
            }
            if (view.updateLayout) view.updateLayout();
        } catch (e) {
            log('resize failed', e);
        }
    }

    function schedule(view) {
        if (isDisabled() || !view) return;
        const raf = window.requestAnimationFrame
            ? window.requestAnimationFrame.bind(window)
            : (cb) => setTimeout(cb, 16);
        raf(() => raf(() => measure(view)));
        setTimeout(() => measure(view), 80);
        setTimeout(() => measure(view), 300);
    }

    function attach(view) {
        if (!view || view.__pmsAutoHeightAttached) return;
        if (!view.el || !view.el.dom) return;
        view.__pmsAutoHeightAttached = true;
        const table = findContentTable(view.el.dom);
        if (table && window.ResizeObserver) {
            const observer = new ResizeObserver(() => {
                if (!isDisabled()) schedule(view);
            });
            observer.observe(table);
            view.__pmsAutoHeightObserver = observer;
        }
    }

    function hook() {
        const proto = window.PVE && PVE.node && PVE.node.StatusView && PVE.node.StatusView.prototype;
        if (!proto) return false;
        if (proto.__pmsAutoHeightHooked) return true;
        proto.__pmsAutoHeightHooked = true;
        ['updateTitle', 'updateValues'].forEach((name) => {
            const original = proto[name];
            if (typeof original !== 'function') return;
            proto[name] = function() {
                const result = original.apply(this, arguments);
                schedule(this);
                attach(this);
                return result;
            };
        });
        return true;
    }

    if (!hook()) {
        let tries = 0;
        const timer = setInterval(() => {
            if (hook() || ++tries > 50) clearInterval(timer);
        }, 100);
    }

    function findView() {
        if (!window.Ext || !Ext.getCmp) return null;
        const panels = document.querySelectorAll('[id^="' + PANEL_ID_PREFIX + '"]');
        let candidate = null;
        for (const panel of panels) {
            const rect = panel.getBoundingClientRect
                ? panel.getBoundingClientRect()
                : { height: panel.offsetHeight || 0 };
            if (!panel.offsetParent && (!rect || rect.height === 0)) continue;
            if (!candidate || (panel.offsetHeight || 0) > (candidate.offsetHeight || 0)) {
                candidate = panel;
            }
        }
        if (!candidate) return null;
        return Ext.getCmp(candidate.id) || null;
    }

    function scan() {
        if (isDisabled()) return;
        const view = findView();
        if (view) {
            attach(view);
            schedule(view);
        }
    }

    function watch() {
        if (!document.body) return;
        // 节点切换/首次创建时靠 updateTitle/updateValues 可能来不及，2 秒兜底扫描一次
        setInterval(scan, 2000);
        scan();
    }

    if (document.body) {
        watch();
    } else {
        document.addEventListener('DOMContentLoaded', watch, { once: true });
    }
})();
EOF

# 验证修改是否成功
if grep -q "itemId: 'cpupower'" "$pvemanagerlib" && grep -q "pve-manager-status-auto-height" "$pvemanagerlib"; then
    echo "已完成修改: $pvemanagerlib ✅"
else
    echo "⛔ 检查对 $pvemanagerlib 添加的内容未生效!"
    rm -f "$tmpf2"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容"
    echo && exit 1
fi

rm -f "$tmpf2"



# 强制概要页面监控信息右对齐
patch_widgets=(
    "widget.pveDcGuests"
    "widget.pveNodeStatus"
)

for widget_alias in "${patch_widgets[@]}"; do
    # 寻找起始行
    start_line=$(sed -n "/$widget_alias/=" "$pvemanagerlib" | head -n1)

    [ -z "$start_line" ] && echo "错误: 修补点不存在 ($widget_alias) ⛔ " && continue

    # 在目标后20行内寻找关键字
    rel_line=$(sed -n "$((start_line)),+$((20))p" "$pvemanagerlib" \
        | sed -n "/width: '100%'/=" \
        | head -n1)

    [ -z "$rel_line" ] && echo "错误: 未找到关键字 ($widget_alias) ⛔ " && continue

    target_line=$((start_line + rel_line - 1))

    # 检查是否已经存在
    next_line=$(sed -n "$((target_line+1))p" "$pvemanagerlib")

    if echo "$next_line" | grep -q "^[[:space:]]*textAlign: 'right',"; then
        echo "警告: 修补点已存在 ($widget_alias) ⚠️"
        continue
    fi

    # 插入更改
    sed -i "${target_line}a\\$(sed -n "${target_line}s/^\([[:space:]]*\).*/\1/p" "$pvemanagerlib")textAlign: 'right'," "$pvemanagerlib"

done

echo && sleep 0.5

####################   zh-CN 本地化   ####################

echo -e "🌏 正在完善 zh-CN 中文本地化:"

case "$pve_major_ver" in
    "8")
        # PVE 8: 添加缺失的中文翻译项目
        echo -e "正在检查并补全 PVE 8 缺失的中文翻译..."

        PVE8_TRANSLATIONS=(
            '"599449289":["传入"]'
            '"669411099":["发送"]'
        )

        # 前置锚点检查
        if ! grep -q "^__proxmox_i18n_msgcat__ =" "$pve_i18n_CN"; then
            echo -e "⛔ 未找到翻译字典中的锚点 (__proxmox_i18n_msgcat__ =), 操作终止!"
            echo -e "⚠️ 文件可能已更新或与当前版本不兼容."
            echo && exit 1
        fi
        
        # 开始逐条处理翻译项目
        for item in "${PVE8_TRANSLATIONS[@]}"; do
            # 提取哈希值作为唯一检查标识
            hash_id=$(echo "$item" | cut -d'"' -f2)
            # 提取中文翻译文本用于日志输出
            zh_text=$(echo "$item" | cut -d'"' -f4)

            # 首先检查哈希值在字典中是否已经存在
            if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                echo -e "已存在 PVE 8 中缺失的中文翻译: [$hash_id] => $zh_text ➡️"
            else
                # 开始执行单次插入
                # 在 }; 前插入一个逗号, 加上当前项目后再闭合 };
                sed -i "/^__proxmox_i18n_msgcat__ =/ s/};$/,${item}\};/" "$pve_i18n_CN"
                
                # 完成后验证插入结果
                if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                    echo -e "已添加 PVE 8 中缺失的中文翻译: [$hash_id] => $zh_text ✅"
                else
                    echo -e "未生效 PVE 8 中缺失的中文翻译: [$hash_id] => $zh_text ⛔"
                fi
            fi
        done

        # PVE 8: 补全缺失的fieldTitles
        patch_titles=(
            "netin netout|Incoming Outgoing"
            "diskread diskwrite|Reads Writes"
        )

        for item in "${patch_titles[@]}"; do
            IFS='|' read -r fields_en titles_en <<< "$item"
            read -r f1 f2 <<< "$fields_en"
            read -r t1 t2 <<< "$titles_en"

            fields_anchor="fields: ['$f1', '$f2']"
            titles_insert="fieldTitles: [gettext('$t1'), gettext('$t2')]"

            fields_label="$f1/$f2"

            # 前置锚点检查
            if ! grep -Fq "$fields_anchor" "$pvemanagerlib"; then
                echo -e "⛔ 未找到 $fields_label 的锚点, 操作终止!"
                echo -e "⚠️ 锚点 \"fields: ['$f1', '$f2']\", 文件可能已更新或与当前版本不兼容."
                echo && exit 1
            fi

            # 检查fieldTitles在文件中是否已经存在
            if grep -Fq "$titles_insert" "$pvemanagerlib"; then
                echo -e "$fields_label 图表按钮的中文翻译已被修正, 跳过该步骤 ➡️"
                continue
            fi

            # 执行插入操作
            sed -i "s/^\([[:space:]]*\)fields: \['$f1', '$f2'\],/&\n\1$titles_insert,/" "$pvemanagerlib"

            # 完成后验证插入结果
            if grep -Fq "$titles_insert" "$pvemanagerlib"; then
                echo -e "已添加 PVE 8 中缺失的字段标题: $fields_label => $t1/$t2 ✅"
            else
                echo -e "未生效 PVE 8 中缺失的字段标题: $fields_label => $t1/$t2 ⛔"
            fi
        done
        ;;
    "9")
        # PVE 9: 添加缺失的中文翻译项目
        echo -e "正在检查并补全 PVE 9 缺失的中文翻译..."

        PVE9_TRANSLATIONS=(
            '"1208454600":["平均值"]'
            '"1653956129":["最大值"]'
            '"871356310":["服务器负载"]'
            '"1299201244":["网络流量"]'
            '"755456338":["CPU 压力停滞"]'
            '"858045066":["IO 压力停滞"]'
            '"431218371":["内存压力停滞"]'
            '"1102487829":["内存使用率"]'
            '"517429357":["主机内存使用量"]'
            '"1075229421":["主机内存使用量"]'
        )

        # 全局前置检查：确保翻译字典的锚点行确实存在
        if ! grep -q "^__proxmox_i18n_msgcat__ =" "$pve_i18n_CN"; then
            echo -e "⛔ 未找到翻译字典中的锚点 (__proxmox_i18n_msgcat__ =), 操作终止!"
            echo -e "⚠️ 文件可能已更新或与当前版本不兼容."
            echo && exit 1
        fi
        
        # 开始逐条处理翻译项目
        for item in "${PVE9_TRANSLATIONS[@]}"; do
            # 提取哈希值作为唯一检查标识
            hash_id=$(echo "$item" | cut -d'"' -f2)
            # 提取中文翻译文本用于日志输出
            zh_text=$(echo "$item" | cut -d'"' -f4)

            # 首先检查哈希值在字典中是否已经存在
            if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                echo -e "已存在 PVE 9 中缺失的中文翻译: [$hash_id] => $zh_text ➡️"
            else
                # 开始执行单次插入
                # 在 }; 前插入一个逗号, 加上当前项目后再闭合 };
                sed -i "/^__proxmox_i18n_msgcat__ =/ s/};$/,${item}\};/" "$pve_i18n_CN"
                
                # 完成后验证插入结果
                if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                    echo -e "已添加 PVE 9 中缺失的中文翻译: [$hash_id] => $zh_text ✅"
                else
                    echo -e "未生效 PVE 9 中缺失的中文翻译: [$hash_id] => $zh_text ⛔"
                fi
            fi
        done
        ;;
    *)
        echo -e "⚠️ 不支持的PVE版本 ($pvever) 跳过 zh-CN 本地化."
        ;;
esac

echo && sleep 0.5

####################   调整页面高度   ####################

echo -e "🎚️ 正在设置集群统一页面高度:"

# 集群共享前端: 高度不能按单机硬件数量计算, 否则切换节点会遮挡或留白.
# 默认 1600px, 可用 PVE_MANAGER_STATUS_HEIGHT 在所有节点统一覆盖.
cluster_height="${PVE_MANAGER_STATUS_HEIGHT:-1600}"
if ! [[ "$cluster_height" =~ ^[0-9]+$ ]] || [ "$cluster_height" -lt 800 ]; then
    cluster_height=1600
fi

sed -i -E "/Ext[.]define[(]'PVE[.]node[.]StatusView'/,/height:/{s/height: *[0-9]+/height: ${cluster_height}/;}" "$pvemanagerlib"
echo "页面高度已统一设置为 ${cluster_height}px ✅"
echo -e "⚠️ 集群模式下所有节点使用同一高度; 如硬件更多, 请在所有节点设置 PVE_MANAGER_STATUS_HEIGHT"

echo && sleep 0.5

####################   修改全部完成后重启服务   ####################

text="🔁 正在重启 pveproxy.service:"

timeout 10s systemctl restart pveproxy.service &> /dev/null &
pid=$!

spinner "$pid" "$text"

wait "$pid"
restart_status=$?
if [ $restart_status -ne 0 ]; then
    if [ $restart_status -eq 124 ]; then
        echo -e "\n⛔ 重启服务 pveproxy.service 超时 (timeout 10s)"
    else
        echo -e "\n⛔ 重启服务 pveproxy.service 失败 ($restart_status)"
    fi
    echo -e "\n⚠️ 请检查服务状态信息以排查问题\n"
    systemctl status pveproxy.service --no-pager
    echo && exit 1
fi
echo "已完成 ✅" && sleep 0.5

####################   Rollback 命令生成   ####################

rollback_commands=()

for file in "$nodes" "$pvemanagerlib" "$pve_i18n_CN"; do
    if ! cmp -s "$file" "${file}.${pvever}.bak"; then
        rollback_commands+=("cp '${file}.${pvever}.bak' '$file'")
    fi
done

echo -e "\n✅ 修改完成, 如需回滚本次修改请执行以下命令:\n"

if [ ${#rollback_commands[@]} -gt 0 ]; then
    printf -v rollback_cmd '%s && ' "${rollback_commands[@]}"
    echo "${rollback_cmd}systemctl restart pveproxy.service"
else
    echo -e "♻️ 在本次修改中文件内容均未发生变更."
fi

echo -e "\n🧹 如需连同阵列卡监控一起完整恢复 PVE 原始状态, 请执行:"
echo -e "   bash ${SCRIPT_DIR}/pve-manager-status.sh restore\n"

echo -e "\n♻️ 请使用 Ctrl + Shift + R 刷新浏览器 Proxmox VE Web 管理页面缓存\n"
