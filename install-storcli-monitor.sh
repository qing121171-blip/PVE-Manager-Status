#!/bin/bash
# =====================================================================
# PVE-Manager-Status 扩展：MegaRAID 阵列卡 SMART 监控（工业级安装器）
#
# 架构：
#   systemd timer (5 分钟)
#       -> /usr/local/bin/pve_storcli_cache_updater.sh
#       -> /usr/local/bin/pve_storcli_parser.py
#       -> /var/cache/pve-manager/storcli_status.cache
#   PVE 的 Nodes.pm 只读取缓存文件，不执行任何耗时命令
#   pvemanagerlib.js 解析缓存文本并渲染
#
# 特性：
#   - 后台定时刷新，PVE 页面秒开
#   - 安装/重复安装幂等
#   - 自动生成 .storcli.bak 备份，可用 uninstall-storcli-monitor.sh 一键还原
# =====================================================================

umask 022

nodes_file="${PVE_NODES_PM:-/usr/share/perl5/PVE/API2/Nodes.pm}"
js_file="${PVE_PVEMANAGERLIB:-/usr/share/pve-manager/js/pvemanagerlib.js}"
parser_file="/usr/local/bin/pve_storcli_parser.py"
updater_file="/usr/local/bin/pve_storcli_cache_updater.sh"
sudoers_file="/etc/sudoers.d/pve-storcli"
cache_dir="/var/cache/pve-manager"
cache_file="${cache_dir}/storcli_status.cache"
legacy_parser_cache_dir="/var/cache/pve-manager-status"
state_dir="/var/lib/pve-manager-status"
state_file="${state_dir}/storcli-height.state"
systemd_dir="/etc/systemd/system"
service_file="${systemd_dir}/pve-storcli-cache.service"
timer_file="${systemd_dir}/pve-storcli-cache.timer"

disk_height="${PVE_STORCLI_DISK_HEIGHT:-51}"
if ! [[ "$disk_height" =~ ^[0-9]+$ ]]; then
    disk_height=51
fi

get_statusview_height() {
    grep -A 40 "Ext.define('PVE.node.StatusView'" "$js_file" \
        | grep -m1 'height:' \
        | sed -E 's/[^0-9]//g'
}

echo -e "\n🛠️ 准备为 PVE-Manager-Status 注入阵列卡 SMART 监控"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    exit 1
fi

if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "⛔ 未检测到 Proxmox VE 环境, 终止执行!"
    exit 1
fi

pvever=$(pveversion | awk -F"/" '{print $2}')
echo -e "⚙️ 当前 Proxmox VE 版本: ${pvever:-未知}"

if [ ! -f "$nodes_file" ] || [ ! -f "$js_file" ]; then
    echo -e "⛔ 未找到 PVE 后端或前端文件, 终止执行!"
    echo -e "   ${nodes_file}"
    echo -e "   ${js_file}"
    exit 1
fi

if ! grep -q '\$res->{sata_status}' "$nodes_file"; then
    echo -e "⛔ 未在 Nodes.pm 中找到 \$res->{sata_status}, 请先执行 pve-manager-status.sh"
    exit 1
fi

if ! grep -q "itemId: 'sata_status'" "$js_file"; then
    echo -e "⛔ 未在 pvemanagerlib.js 中找到 sata_status 模块, 请先执行 pve-manager-status.sh"
    exit 1
fi

smartctl_path=$(command -v smartctl || true)
if [ -z "$smartctl_path" ] || [ ! -x "$smartctl_path" ]; then
    echo -e "⛔ 未找到 smartctl, 请先安装 smartmontools (apt install smartmontools)"
    exit 1
fi
echo -e "🔎 smartctl 路径: ${smartctl_path}"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "⛔ 未找到 python3, 无法生成 SMART 解析器"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "⛔ 未找到 systemctl, 无法配置定时缓存"
    exit 1
fi

storcli_bin=$(command -v storcli64 || command -v storcli || true)
if [ -n "$storcli_bin" ]; then
    echo -e "🔎 storcli 路径: ${storcli_bin}"
else
    echo -e "⚠️ 未找到 storcli64/storcli; 本方案使用 smartctl 直接读取阵列卡, 可继续安装"
fi

# ==========================================
# 1. 备份（仅在尚未注入时刷新备份，保证回滚点是“注入前”状态）
# ==========================================
echo -e "\n💾 正在检查备份:"

if ! grep -q 'storcli_status' "$nodes_file"; then
    cp -a "$nodes_file" "${nodes_file}.storcli.bak"
    echo "已生成备份: ${nodes_file}.storcli.bak ✅"
else
    if [ -f "${nodes_file}.storcli.bak" ]; then
        echo "保留已有备份: ${nodes_file}.storcli.bak ➡️"
    else
        echo -e "⚠️ 检测到 Nodes.pm 已有注入但备份缺失; 不创建被污染的备份, 卸载时将使用兜底清理"
    fi
fi

if ! grep -q "itemId: 'storcli_status'" "$js_file"; then
    cp -a "$js_file" "${js_file}.storcli.bak"
    echo "已生成备份: ${js_file}.storcli.bak ✅"
else
    if [ -f "${js_file}.storcli.bak" ]; then
        echo "保留已有备份: ${js_file}.storcli.bak ➡️"
    else
        echo -e "⚠️ 检测到 pvemanagerlib.js 已有注入但备份缺失; 不创建被污染的备份, 卸载时将使用兜底清理"
    fi
fi

# ==========================================
# 2. 生成 Python 解析器
# ==========================================
echo -e "\n🐍 正在生成 Python 解析器: ${parser_file}"

if ! install -d -m 0755 "$state_dir"; then
    echo -e "⛔ 无法创建状态目录: ${state_dir}"
    exit 1
fi

# 解析器内部 TTL 缓存目录（仅用于手动调试；正式缓存由 systemd 写入 /var/cache/pve-manager）
if getent group www-data >/dev/null 2>&1; then
    install -d -m 0775 -o root -g www-data "$legacy_parser_cache_dir"
else
    install -d -m 0755 -o root -g root "$legacy_parser_cache_dir"
fi

parser_tmp="${parser_file}.tmp.$$"

cat > "$parser_tmp" << 'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# LSI MegaRAID 物理硬盘 SMART 解析器
# 输出格式（多块盘用 || 分隔）：
#   型号|温度|通电时间|坏道|健康状态|无法纠错数|序列号|生产日期|读取GB|写入GB|不安全断电|寿命
#
# 说明：
#   - 统一使用 LC_ALL=C 读取 smartctl 输出，避免本地化导致的解析失败
#   - 支持 --refresh 强制刷新；systemd 定时器通过该参数绕过内部 60 秒缓存
#   - 内部 TTL 缓存仅用于手动调试，PVE 页面本身只读取 /var/cache/pve-manager 下的缓存
#   - 可使用环境变量覆盖以下参数（便于调试）：
#       PVE_STORCLI_SMARTCTL / PVE_STORCLI_CACHE_DIR / PVE_STORCLI_TTL

import fcntl
import os
import re
import shutil
import subprocess
import sys
import time

CACHE_DIR = os.environ.get("PVE_STORCLI_CACHE_DIR", "/var/cache/pve-manager-status")
CACHE_FILE = os.path.join(CACHE_DIR, "storcli.cache")
LOCK_FILE = os.path.join(CACHE_DIR, "storcli.lock")

try:
    TTL = max(5, int(os.environ.get("PVE_STORCLI_TTL", "60")))
except ValueError:
    TTL = 60

SMARTCTL_DEFAULT = "/usr/sbin/smartctl"
SMARTCTL = os.environ.get("PVE_STORCLI_SMARTCTL") or (
    SMARTCTL_DEFAULT
    if os.path.exists(SMARTCTL_DEFAULT)
    else (shutil.which("smartctl") or SMARTCTL_DEFAULT)
)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


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
    # pvedaemon 以 root 运行时直接调用；www-data 调用时依赖 sudoers
    if os.geteuid() == 0:
        return _run([SMARTCTL] + args, timeout=timeout)
    return _run(["sudo", "-n", SMARTCTL] + args, timeout=timeout)


def _attr_raw(line):
    parts = line.split()
    if len(parts) >= 10:
        return parts[9]
    return ""


def _attr_value(line):
    """SMART 属性的归一化 VALUE 列（第 4 列，索引 3）。"""
    parts = line.split()
    if len(parts) >= 10:
        return parts[3]
    return ""


# 不同 SSD 厂商表示“剩余寿命/磨损指标”的属性名
LIFE_ATTRIBUTES = (
    "Media_Wearout_Indicator",
    "Wear_Leveling_Count",
    "SSD_Life_Left",
    "Percent_Lifetime_Remain",
    "Remaining_Lifetime_Perc",
)


def _leading_int(value):
    match = re.match(r"(\d+)", value or "")
    return int(match.group(1)) if match else None


def _clean(value, fallback="-"):
    value = str(value).replace("|", "/").replace("\r", " ").replace("\n", " ").strip()
    return value if value else fallback


def parse_disk(text):
    """解析单块盘的 smartctl -a 输出，失败时返回 None。"""
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
    unsafe_shutdown = "-"
    life = "-"
    is_ssd = False

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
        elif line.startswith(("read:", "write:", "verify:")):
            # SAS Error counter log:
            # read: ... <gigabytes processed> <total uncorrected errors>
            parts = line.split()
            if len(parts) >= 8:
                try:
                    gb_value = float(parts[6])
                    unc_value = int(parts[7])
                except ValueError:
                    pass
                else:
                    if line.startswith("read:"):
                        read_gb = gb_value
                    elif line.startswith("write:"):
                        write_gb = gb_value
                    if unc_value > 0:
                        uncorrected += unc_value
        elif "Reported_Uncorrect" in line:
            value = _leading_int(_attr_raw(line))
            if value:
                uncorrected += value
        elif "Unsafe_Shutdown_Count" in line or "Power_Loss_Count" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                unsafe_shutdown = value
        elif any(name in line for name in LIFE_ATTRIBUTES):
            # SSD 的剩余寿命看归一化 VALUE 列，例如 Intel 的 233 = 099 表示 99%
            value = _leading_int(_attr_value(line))
            if value is not None:
                life = value
        elif "Percentage used endurance indicator:" in line:
            # SAS SSD：用“已用寿命百分比”反推剩余寿命
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
                read_gb = value * 512.0 / 1000000000.0
        elif "Total_LBAs_Written" in line:
            value = _leading_int(_attr_raw(line))
            if value is not None:
                write_gb = value * 512.0 / 1000000000.0
        elif line.startswith("Rotation Rate:") and "Solid State" in line:
            is_ssd = True

    if model == "未知":
        return None

    # SATA SSD 的 smartctl 输出没有生产日期字段。
    # Intel SSD 的 ISN/SN 第 5 位是年份、第 6-7 位是周数，例如 PHWA631... => 2016 年第 31 周。
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
        _clean(unsafe_shutdown, "-"),
        _clean(life, "-"),
    ]
    return "|".join(values)


def list_devices():
    devices = []
    seen = set()
    pattern = re.compile(r"^(/dev/bus/\d+)\s+-d\s+megaraid,(\d+)\b")

    for option in ("--scan", "--scan-open"):
        output = _smartctl([option], timeout=20)
        for line in output.splitlines():
            match = pattern.match(line.strip())
            if not match:
                continue
            key = (match.group(1), int(match.group(2)))
            if key not in seen:
                seen.add(key)
                devices.append(key)
        if devices:
            break

    devices.sort(key=lambda item: (item[0], item[1]))
    return devices


def refresh():
    devices = list_devices()
    rows = []
    for dev_path, did in devices:
        output = _smartctl(
            ["-a", "-d", "megaraid,{}".format(did), dev_path],
            timeout=20,
        )
        if not output:
            continue
        row = parse_disk(output)
        if row:
            rows.append(row)
    return "||".join(rows), len(devices)


def _ensure_cache_files():
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        os.chmod(CACHE_DIR, 0o775)
    except OSError:
        pass

    try:
        import grp

        gid = grp.getgrnam("www-data").gr_gid
    except (ImportError, KeyError):
        gid = None

    for path in (CACHE_FILE, LOCK_FILE):
        try:
            fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o664)
            os.close(fd)
            os.chmod(path, 0o664)
            if os.geteuid() == 0 and gid is not None:
                os.chown(path, 0, gid)
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
        os.chmod(tmp_file, 0o664)
        os.replace(tmp_file, CACHE_FILE)
    except OSError:
        try:
            os.unlink(tmp_file)
        except OSError:
            pass


def main():
    force_refresh = "--refresh" in sys.argv
    if not force_refresh:
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
            # 另一个进程正在刷新，直接返回上一次的旧数据
            print(read_cache(ignore_ttl=True) or "")
            return 0

        value, device_count = refresh()
        stale = read_cache(ignore_ttl=True)

        if value:
            write_cache(value)
            print(value)
            return 0

        if device_count == 0:
            # 没有 megaraid 设备：清空内部缓存，退出码 2 供缓存更新器写入空缓存
            write_cache("")
            print("")
            return 2

        # 有设备但全部读取失败：保留上一份有效数据，退出码 1
        if stale:
            print(stale)
            return 0
        print("")
        return 1
    except Exception:
        stale = read_cache(ignore_ttl=True)
        print(stale or "")
        return 0 if stale else 1
    finally:
        if lock_handle is not None:
            try:
                fcntl.flock(lock_handle, fcntl.LOCK_UN)
            except Exception:
                pass
            lock_handle.close()


if __name__ == "__main__":
    sys.exit(main())
PYEOF

chmod 0755 "$parser_tmp"
chown root:root "$parser_tmp"

# 把 smartctl 的实际路径写入解析器，保证与 sudoers 中的路径完全一致
sed -i "s|^SMARTCTL_DEFAULT = .*|SMARTCTL_DEFAULT = \"${smartctl_path}\"|" "$parser_tmp"

# 做一次 Python 语法检查（compile 不会生成 __pycache__）
if ! python3 - "$parser_tmp" << 'PYCHECK'
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    compile(handle.read(), sys.argv[1], "exec")
PYCHECK
then
    echo -e "⛔ Python 解析器语法检查失败"
    rm -f "$parser_tmp"
    exit 1
fi

if ! mv -f "$parser_tmp" "$parser_file"; then
    echo -e "⛔ 无法写入解析器: ${parser_file}"
    rm -f "$parser_tmp"
    exit 1
fi
echo "解析器已生成 ✅"

# ==========================================
# 3. 生成缓存更新脚本
# ==========================================
echo -e "\n🔄 正在生成缓存更新脚本: ${updater_file}"

install -d -m 0755 -o root -g root "$cache_dir" || {
    echo -e "⛔ 无法创建缓存目录: ${cache_dir}"
    exit 1
}

cat > "$updater_file" << 'UPDATER'
#!/bin/bash
# PVE storcli SMART cache updater
# 由 systemd timer 每 5 分钟调用一次，也可手动执行。
set -u

CACHE_DIR="/var/cache/pve-manager"
CACHE_FILE="${CACHE_DIR}/storcli_status.cache"
PARSER="/usr/local/bin/pve_storcli_parser.py"

mkdir -p "$CACHE_DIR" || exit 1
tmp_file=$(mktemp "${CACHE_FILE}.tmp.XXXXXX") || exit 1
trap 'rm -f "$tmp_file"' EXIT

output=""
if output=$("$PARSER" --refresh 2>/dev/null); then
    rc=0
else
    rc=$?
fi

case "$rc" in
    0)
        if [ -n "$output" ]; then
            printf '%s\n' "$output" > "$tmp_file"
        else
            printf '\n' > "$tmp_file"
        fi
        ;;
    2)
        # 没有 megaraid 设备：写入空缓存，前端会显示“暂无数据”
        printf '\n' > "$tmp_file"
        ;;
    *)
        echo "pve-storcli: parser failed (exit ${rc}), keeping last good cache" >&2
        if [ -s "$CACHE_FILE" ]; then
            exit 0
        fi
        printf '\n' > "$tmp_file"
        ;;
esac

chmod 0644 "$tmp_file"
chown root:root "$tmp_file"
mv -f "$tmp_file" "$CACHE_FILE"
echo "pve-storcli: cache updated: ${CACHE_FILE}"
UPDATER

chmod 0755 "$updater_file"
chown root:root "$updater_file"

# ==========================================
# 4. 配置 systemd 定时缓存
# ==========================================
echo -e "\n⏱️ 正在配置 systemd 定时缓存:"

cat > "$service_file" << EOF
[Unit]
Description=PVE storcli SMART cache updater
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${updater_file}
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=180
EOF

cat > "$timer_file" << EOF
[Unit]
Description=Refresh PVE storcli SMART cache every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=pve-storcli-cache.service

[Install]
WantedBy=timers.target
EOF

if ! systemctl daemon-reload; then
    echo -e "⛔ systemctl daemon-reload 失败"
    exit 1
fi
if ! systemctl enable pve-storcli-cache.timer; then
    echo -e "⛔ 无法启用 pve-storcli-cache.timer"
    exit 1
fi
echo "定时器已启用: pve-storcli-cache.timer ✅"

# ==========================================
# 5. 配置 sudoers 权限
# ==========================================
echo -e "\n🔐 正在配置 sudoers 权限:"

if [ ! -d /etc/sudoers.d ]; then
    echo -e "⛔ 未找到 /etc/sudoers.d 目录"
    exit 1
fi

tmp_sudoers=$(mktemp /tmp/pve-storcli-sudoers.XXXXXX) || exit 1
cat > "$tmp_sudoers" << EOF
# Managed by install-storcli-monitor.sh (PVE-Manager-Status extension)
# systemd timer runs as root; these rules are for manual www-data debugging only.
www-data ALL=(root) NOPASSWD: ${smartctl_path} --scan
www-data ALL=(root) NOPASSWD: ${smartctl_path} --scan-open
# 注意: sudoers 中逗号是命令分隔符, 这里用 ? 通配逗号, 避免写成 megaraid,*
www-data ALL=(root) NOPASSWD: ${smartctl_path} -a -d megaraid?* /dev/bus/*
www-data ALL=(root) NOPASSWD: ${parser_file}
EOF

if ! visudo -c -f "$tmp_sudoers" >/dev/null 2>&1; then
    echo -e "⛔ sudoers 规则语法错误, 操作终止!"
    echo "--------------------------------------------------"
    cat "$tmp_sudoers"
    echo "--------------------------------------------------"
    visudo -c -f "$tmp_sudoers"
    rm -f "$tmp_sudoers"
    exit 1
fi

if ! install -m 0440 -o root -g root "$tmp_sudoers" "$sudoers_file"; then
    echo -e "⛔ 无法写入 sudoers 文件: ${sudoers_file}"
    rm -f "$tmp_sudoers"
    exit 1
fi
rm -f "$tmp_sudoers"
echo "已写入 sudoers: ${sudoers_file} ✅"

# ==========================================
# 6. 修改 Perl 后端 (Nodes.pm)
# ==========================================
echo -e "\n📋 正在配置 Perl 后端:"

python3 - "$nodes_file" << 'PYEOF'
import os
import re
import sys
import tempfile

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as handle:
    lines = handle.readlines()

# 幂等：先删除旧注入（任何引用 storcli_status 的行）
lines = [line for line in lines if "storcli_status" not in line]

anchor = None
for index, line in enumerate(lines):
    if "$res->{sata_status}" in line:
        anchor = index
        break

if anchor is None:
    sys.exit(2)

indent_match = re.match(r"^(\s*)", lines[anchor])
indent = indent_match.group(1) if indent_match else "        "
new_line = indent + "$res->{storcli_status} = '正在后台获取数据...';\n"
new_line += indent + "eval { $res->{storcli_status} = PVE::Tools::file_get_contents('/var/cache/pve-manager/storcli_status.cache'); };\n"
lines.insert(anchor + 1, new_line)

directory = os.path.dirname(path)
fd, tmp_path = tempfile.mkstemp(prefix=".pve-storcli-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(lines)
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PYEOF

nodes_py_rc=$?
if [ "$nodes_py_rc" -ne 0 ]; then
    echo -e "⛔ Nodes.pm 注入失败 (退出码: ${nodes_py_rc})"
    [ -f "${nodes_file}.storcli.bak" ] && cp -a "${nodes_file}.storcli.bak" "$nodes_file"
    exit 1
fi

if ! grep -q '\$res->{storcli_status}' "$nodes_file"; then
    echo -e "⛔ 检查到 Nodes.pm 注入未生效"
    [ -f "${nodes_file}.storcli.bak" ] && cp -a "${nodes_file}.storcli.bak" "$nodes_file"
    exit 1
fi

# Perl 语法检查，失败立即回滚
if command -v perl >/dev/null 2>&1; then
    perl_check_log=$(mktemp /tmp/pve-storcli-perl.XXXXXX) || perl_check_log=""
    if [ -n "$perl_check_log" ]; then
        if ! timeout 30s perl -c "$nodes_file" >"$perl_check_log" 2>&1; then
            echo -e "⛔ Nodes.pm  Perl 语法检查失败, 已回滚:"
            cat "$perl_check_log"
            rm -f "$perl_check_log"
            [ -f "${nodes_file}.storcli.bak" ] && cp -a "${nodes_file}.storcli.bak" "$nodes_file"
            exit 1
        fi
        rm -f "$perl_check_log"
    fi
fi
echo "Nodes.pm 注入完成 ✅"

# ==========================================
# 7. 修改 JS 前端 (pvemanagerlib.js)
# ==========================================
echo -e "\n🎨 正在配置 JS 前端:"

python3 - "$js_file" << 'PYEOF'
import os
import re
import sys
import tempfile

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()

BEGIN = "// >>> PVE-MANAGER-STATUS: storcli_status (managed by install-storcli-monitor.sh) >>>"
END = "// <<< PVE-MANAGER-STATUS: storcli_status <<<"

MODULE = r"""
// >>> PVE-MANAGER-STATUS: storcli_status (managed by install-storcli-monitor.sh) >>>
{
    itemId: 'storcli_status',
    colspan: 2,
    printBar: false,
    title: gettext('阵列卡硬盘 (SMART)'),
    textField: 'storcli_status',
    renderer: function(value) {
        if (!value || String(value).trim() === '') {
            return '提示: 未检测到阵列卡物理硬盘 (请检查 smartctl -d megaraid 是否可用)';
        }
        if (String(value).indexOf('正在后台获取数据') !== -1) {
            return esc(String(value).trim());
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
        function getLifeColor(life) {
            var n = parseInt(life, 10);
            if (isNaN(n)) return null;
            if (n < 50) return 'var(--pve-manager-status-high, #ff0000)';
            if (n < 80) return 'var(--pve-manager-status-medium, #ffa500)';
            return 'var(--pve-manager-status-low, #008000)';
        }
        function colorizeModel(model, life, health) {
            // 与 NVMe 一致：SSD 按寿命着色；HDD 没有寿命字段时按健康状态着色
            var color = getLifeColor(life);
            if (!color) color = health === 'OK' ? 'var(--pve-manager-status-low, #008000)' : 'var(--pve-manager-status-high, #ff0000)';
            return '<span style="color:' + color + '; font-weight:bold;">' + esc(model) + '</span>';
        }
        function colorizeTemp(temp) {
            var t = parseInt(temp, 10);
            if (isNaN(t)) return '<span>' + esc(temp) + '</span>';
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
            var color = getLifeColor(life);
            return '<span style="color:' + color + '; font-weight:bold;">' + n + '%</span>';
        }
        function colorizeUnsafe(count) {
            // NVMe 模块中的“不安全断电”是不高亮的普通文本，这里保持一致
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
            var healthColor = health === 'OK' ? 'var(--pve-manager-status-low, #008000)' : 'var(--pve-manager-status-high, #ff0000)';
            var line1 = colorizeModel(model, life, health) + ' | 温度: ' + colorizeTemp(temp) +
                        ' | 通电: ' + (isNaN(hours) ? esc(hour) : hours + 'h (' + years + '年)') +
                        ' | 状态: <span style="color:' + healthColor + '; font-weight:bold;">' + esc(health) + '</span>';
            var line2 = 'SN: ' + esc(serial) +
                        ' | 生产: ' + esc(mfg) + ' | 坏道: ' + colorizeNum(defects, false) +
                        ' | 无法纠错: ' + colorizeNum(uncorrected, true);
            var line3Parts = [];
            if (!isNaN(parseInt(life, 10))) line3Parts.push('寿命: ' + colorizeLife(life));
            if (!isNaN(parseInt(unsafe, 10))) line3Parts.push('不安全断电: ' + colorizeUnsafe(unsafe));
            line3Parts.push('已读: ' + formatSize(readgb));
            line3Parts.push('已写: ' + formatSize(writegb));
            var line3 = line3Parts.join(' | ');
            output.push(line1 + '<br>' + line2 + '<br>' + line3);
        }
        return output.join('<br>');
    }
},
// <<< PVE-MANAGER-STATUS: storcli_status <<<
"""


def skip_string(text, index):
    quote = text[index]
    index += 1
    length = len(text)
    while index < length:
        char = text[index]
        if char == "\\":
            index += 2
            continue
        if char == quote:
            return index + 1
        index += 1
    return length


def skip_line_comment(text, index):
    end = text.find("\n", index)
    return len(text) if end == -1 else end


def skip_block_comment(text, index):
    end = text.find("*/", index + 2)
    return len(text) if end == -1 else end + 2


REGEX_PREV_CHARS = set("(,=:[!&|?{};+-*%<>~^")


def looks_like_regex(text, index):
    """判断 / 是正则字面量的开始还是除号（JS 没有完美的静态判定，这里覆盖常见写法）。"""
    position = index - 1
    while position >= 0 and text[position] in " \t\r\n":
        position -= 1
    if position < 0:
        return True

    previous = text[position]
    if previous in REGEX_PREV_CHARS:
        return True

    if previous.isalnum() or previous in "_$)]\"'`":
        prefix = text[:index].rstrip()
        for keyword in (
            "return", "typeof", "case", "delete", "void", "instanceof",
            "in", "of", "new", "do", "else", "yield", "await",
        ):
            if prefix.endswith(keyword):
                cut = len(prefix) - len(keyword)
                before = prefix[cut - 1] if cut > 0 else ""
                if not (before.isalnum() or before in "_$"):
                    return True
        return False

    return True


def skip_regex(text, index):
    index += 1
    in_class = False
    length = len(text)
    while index < length:
        char = text[index]
        if char == "\\":
            index += 2
            continue
        if char == "\n":
            return index
        if char == "[":
            in_class = True
        elif char == "]":
            in_class = False
        elif char == "/" and not in_class:
            return index + 1
        index += 1
    return length


def find_matching_brace(text, start):
    depth = 0
    index = start
    length = len(text)
    while index < length:
        char = text[index]
        if char in "\"'`":
            index = skip_string(text, index)
            continue
        if char == "/" and index + 1 < length:
            if text[index + 1] == "/":
                index = skip_line_comment(text, index)
                continue
            if text[index + 1] == "*":
                index = skip_block_comment(text, index)
                continue
            if looks_like_regex(text, index):
                index = skip_regex(text, index)
                continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


# 幂等：优先按管理标记删除旧块
while BEGIN in content:
    begin = content.find(BEGIN)
    line_start = content.rfind("\n", 0, begin) + 1
    end = content.find(END, begin)
    if end == -1:
        content = content[:line_start]
        break
    line_end = content.find("\n", end)
    line_end = len(content) if line_end == -1 else line_end + 1
    content = content[:line_start] + content[line_end:]

# 兼容旧版本：没有管理标记时，按 itemId 做花括号配对删除
while "itemId: 'storcli_status'" in content:
    position = content.find("itemId: 'storcli_status'")
    start = content.rfind("{", 0, position)
    if start == -1:
        break
    end = find_matching_brace(content, start)
    if end == -1:
        break
    end += 1
    probe = end
    while probe < len(content) and content[probe] in " \t":
        probe += 1
    if probe < len(content) and content[probe] == ",":
        end = probe + 1
    line_start = content.rfind("\n", 0, start) + 1
    if end < len(content) and content[end] == "\n":
        end += 1
    content = content[:line_start] + content[end:]

# 定位 sata_status，优先把模块插到它后面（该对象自带结尾逗号，最稳妥）
position = content.find("itemId: 'sata_status'")
if position == -1:
    sys.exit(3)

start = content.rfind("{", 0, position)
if start == -1:
    sys.exit(4)

line_start = content.rfind("\n", 0, start) + 1
indent = content[line_start:start]
if not indent.strip():
    indent = "        "

end = find_matching_brace(content, start)
if end != -1:
    insert_at = end + 1
    probe = insert_at
    while probe < len(content) and content[probe] in " \t":
        probe += 1
    if probe < len(content) and content[probe] == ",":
        insert_at = probe + 1
    else:
        # sata_status 恰好是最后一项时补一个逗号
        content = content[:insert_at] + "," + content[insert_at:]
        insert_at += 1
else:
    # 兜底：直接插到 items 数组结束前
    match = re.search(r"\n[ \t]{0,8}\][,]?", content[position:])
    if not match:
        sys.exit(5)
    insert_at = position + match.start()
    trailing = content[:insert_at].rstrip()
    if not trailing.endswith(","):
        if not trailing.endswith("}"):
            sys.exit(6)
        content = trailing + "," + content[insert_at:]
        insert_at = len(trailing) + 1

module_lines = []
for line in MODULE.strip("\n").splitlines():
    module_lines.append(indent + line if line.strip() else "")
module_block = "\n".join(module_lines)

content = content[:insert_at] + "\n" + module_block + content[insert_at:]

directory = os.path.dirname(path)
fd, tmp_path = tempfile.mkstemp(prefix=".pve-storcli-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PYEOF

js_rc=$?
if [ "$js_rc" -ne 0 ]; then
    echo -e "⛔ pvemanagerlib.js 注入失败 (退出码: ${js_rc})"
    [ -f "${js_file}.storcli.bak" ] && cp -a "${js_file}.storcli.bak" "$js_file"
    exit 1
fi

if ! grep -q "itemId: 'storcli_status'" "$js_file"; then
    echo -e "⛔ 检查到 pvemanagerlib.js 注入未生效"
    [ -f "${js_file}.storcli.bak" ] && cp -a "${js_file}.storcli.bak" "$js_file"
    exit 1
fi
echo "pvemanagerlib.js 注入完成 ✅"

# ==========================================
# 8. 生成初始缓存并统计硬盘数量
# ==========================================
echo -e "\n🧪 正在生成初始缓存并统计硬盘数量:"

rm -f "$cache_file"
if timeout 180s "$updater_file"; then
    echo "初始缓存已生成 ✅"
else
    echo -e "⚠️ 初始缓存生成失败或超时; systemd timer 会稍后重试"
fi

parser_output=$(head -n1 "$cache_file" 2>/dev/null | tr -d '\r')
if [ -n "$parser_output" ]; then
    disk_count=$(( $(printf '%s' "$parser_output" | grep -o '||' | wc -l) + 1 ))
    echo "已读取到 ${disk_count} 块阵列卡物理硬盘 ✅"
    echo "样例: $(printf '%s' "$parser_output" | cut -c1-180)..."
else
    disk_count=0
    echo -e "⚠️ 缓存中暂未读到硬盘数据 (可能当前无阵列卡硬盘, 或首次读取失败)"
    scan_count=$(timeout 30s "$smartctl_path" --scan 2>/dev/null | grep -c 'megaraid,')
    disk_count=${scan_count:-0}
    if [ "$disk_count" -gt 0 ]; then
        echo -e "   已通过 smartctl --scan 统计到 ${disk_count} 块盘, 将按此数量预留高度"
    else
        echo -e "   可稍后执行: systemctl start pve-storcli-cache.service"
    fi
fi

if systemctl start pve-storcli-cache.timer; then
    echo "定时器已启动: pve-storcli-cache.timer ✅"
else
    echo -e "⚠️ 定时器启动失败, 请手动执行: systemctl start pve-storcli-cache.timer"
fi

# ==========================================
# 9. 动态追加阵列卡所需页面高度
# ==========================================
echo -e "\n🎚️ 正在追加阵列卡监控区域高度:"

current_h=$(get_statusview_height)

if ! [[ "$current_h" =~ ^[0-9]+$ ]]; then
    echo -e "⛔ 无法读取 PVE.node.StatusView 的 height, 跳过高度调整"
else
    base_h="$current_h"
    prev_inc=0

    if [ -f "$state_file" ]; then
        read -r prev_base prev_inc < "$state_file" || true
        if [[ "$prev_base" =~ ^[0-9]+$ ]] && [[ "$prev_inc" =~ ^[0-9]+$ ]]; then
            if [ "$current_h" -eq $((prev_base + prev_inc)) ]; then
                base_h="$prev_base"
            fi
        fi
    fi

    height_inc=$((disk_count * disk_height))
    new_height=$((base_h + height_inc))

    if [ "$new_height" -ne "$current_h" ]; then
        sed -i -E "/Ext[.]define[(]'PVE[.]node[.]StatusView'/,/height:/{s/height: *[0-9]+/height: ${new_height}/;}" "$js_file"
        applied_h=$(get_statusview_height)
        if [ "$applied_h" != "$new_height" ]; then
            echo -e "⛔ 页面高度写入失败 (期望 ${new_height}px, 实际 ${applied_h:-未知}px)"
        else
            echo "$base_h $height_inc" > "$state_file"
            echo "页面高度: ${current_h}px -> ${new_height}px (基础 ${base_h}px + ${disk_count} 块 * ${disk_height}px) ✅"
        fi
    else
        echo "$base_h $height_inc" > "$state_file"
        echo "页面高度已匹配: ${new_height}px (${disk_count} 块 * ${disk_height}px) ➡️"
    fi
fi

# ==========================================
# 10. 重启服务
# ==========================================
echo -e "\n🔁 正在重启 pvedaemon / pveproxy:"

if timeout 30s systemctl restart pvedaemon.service pveproxy.service; then
    echo "服务已重启 ✅"
else
    echo -e "⚠️ 服务重启失败或超时, 请手动执行: systemctl restart pvedaemon pveproxy"
    systemctl status pvedaemon.service pveproxy.service --no-pager || true
fi

# ==========================================
# 11. 安装完成 / 卸载提示
# ==========================================
echo -e "\n✅ 阵列卡 SMART 监控部署完成!"
echo -e "\n📦 缓存文件: ${cache_file}"
echo -e "⏱️ 定时器  : pve-storcli-cache.timer (每 5 分钟刷新)"
echo -e "🧹 一键卸载: bash $(dirname "$0")/uninstall-storcli-monitor.sh"
echo -e "\n如需查看定时器状态:"
echo -e "   systemctl status pve-storcli-cache.timer --no-pager"
echo -e "   systemctl list-timers pve-storcli-cache.timer --no-pager"
echo -e "\n♻️ 请使用 Ctrl + Shift + R 强制刷新浏览器缓存"
