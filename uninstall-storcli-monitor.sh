#!/bin/bash
# =====================================================================
# PVE-Manager-Status 扩展：MegaRAID 阵列卡 SMART 监控（一键卸载器）
#
# 清理内容：
#   - pve-storcli-cache.timer / pve-storcli-cache.service
#   - /usr/local/bin/pve_storcli_parser.py
#   - /usr/local/bin/pve_storcli_cache_updater.sh
#   - /etc/sudoers.d/pve-storcli
#   - /var/cache/pve-manager/storcli_status.cache
#   - /var/cache/pve-manager-status（旧版解析器内部缓存）
#   - /var/lib/pve-manager-status（高度状态）
#   - Nodes.pm / pvemanagerlib.js 中的注入代码
#
# 还原策略：
#   1. 优先从 .storcli.bak 还原（安装前的干净版本）
#   2. 备份不存在时，退化为精确删除注入代码 + 恢复基础高度
#
# 本脚本可重复执行。
# =====================================================================

umask 022

nodes_file="${PVE_NODES_PM:-/usr/share/perl5/PVE/API2/Nodes.pm}"
js_file="${PVE_PVEMANAGERLIB:-/usr/share/pve-manager/js/pvemanagerlib.js}"
parser_file="/usr/local/bin/pve_storcli_parser.py"
updater_file="/usr/local/bin/pve_storcli_cache_updater.sh"
sudoers_file="/etc/sudoers.d/pve-storcli"
cache_dir="/var/cache/pve-manager"
cache_file="${cache_dir}/storcli_status.cache"
legacy_cache_dir="/var/cache/pve-manager-status"
state_dir="/var/lib/pve-manager-status"
state_file="${state_dir}/storcli-height.state"
systemd_dir="/etc/systemd/system"
service_file="${systemd_dir}/pve-storcli-cache.service"
timer_file="${systemd_dir}/pve-storcli-cache.timer"

echo -e "\n🧹 正在卸载阵列卡 SMART 监控"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    exit 1
fi

changed=0
restored_nodes=0
restored_js=0

# ==========================================
# 1. 停止并删除 systemd 定时任务
# ==========================================
echo -e "\n⏱️ 正在停止定时缓存:"

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now pve-storcli-cache.timer >/dev/null 2>&1 || true
    systemctl stop pve-storcli-cache.service >/dev/null 2>&1 || true
fi

if [ -f "$timer_file" ] || [ -f "$service_file" ]; then
    rm -f "$timer_file" "$service_file"
    changed=1
    echo "已删除 systemd 单元文件 ✅"
else
    echo "systemd 单元文件不存在, 跳过 ➡️"
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed pve-storcli-cache.service >/dev/null 2>&1 || true
fi

# ==========================================
# 2. 还原 PVE 配置文件
# ==========================================
echo -e "\n♻️ 正在还原 PVE 配置文件:"

if [ ! -f "$nodes_file" ] || [ ! -f "$js_file" ]; then
    echo -e "⚠️ 未找到 PVE 配置文件, 跳过还原"
else
    if [ -f "${nodes_file}.storcli.bak" ]; then
        if cp -a "${nodes_file}.storcli.bak" "$nodes_file"; then
            rm -f "${nodes_file}.storcli.bak"
            restored_nodes=1
            changed=1
            echo "已还原: ${nodes_file} ✅"
        else
            echo -e "⛔ 还原失败: ${nodes_file}"
        fi
    else
        echo "未找到 ${nodes_file}.storcli.bak, 将精确删除注入代码"
    fi

    if [ -f "${js_file}.storcli.bak" ]; then
        if cp -a "${js_file}.storcli.bak" "$js_file"; then
            rm -f "${js_file}.storcli.bak"
            restored_js=1
            changed=1
            echo "已还原: ${js_file} ✅"
        else
            echo -e "⛔ 还原失败: ${js_file}"
        fi
    else
        echo "未找到 ${js_file}.storcli.bak, 将精确删除注入代码"
    fi
fi

# ==========================================
# 3. 备份缺失时的兜底清理
# ==========================================
if [ "$restored_nodes" -eq 0 ] && [ -f "$nodes_file" ] && grep -q 'storcli_status' "$nodes_file"; then
    echo -e "\n🧽 未找到 Nodes.pm 备份, 正在删除 storcli_status 注入..."
    nodes_tmp="${nodes_file}.uninstall.tmp"
    cp -a "$nodes_file" "$nodes_tmp" || true
    awk '!/storcli_status/' "$nodes_file" > "${nodes_file}.uninstall.new" && mv -f "${nodes_file}.uninstall.new" "$nodes_file"
    if command -v perl >/dev/null 2>&1 && ! perl -c "$nodes_file" >/dev/null 2>&1; then
        echo -e "⛔ 清理后 Perl 语法检查失败, 正在回滚本次清理"
        [ -f "$nodes_tmp" ] && cp -a "$nodes_tmp" "$nodes_file"
    else
        changed=1
        echo "已删除 Nodes.pm 注入 ✅"
    fi
    rm -f "$nodes_tmp"
fi

if [ "$restored_js" -eq 0 ] && [ -f "$js_file" ] && grep -q "itemId: 'storcli_status'" "$js_file"; then
    echo -e "\n🧽 未找到 pvemanagerlib.js 备份, 正在删除 storcli_status 前端模块..."
    js_tmp="${js_file}.uninstall.tmp"
    cp -a "$js_file" "$js_tmp" || true
    python3 - "$js_file" << 'PYEOF'
import os
import sys
import tempfile

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()

BEGIN = "// >>> PVE-MANAGER-STATUS: storcli_status"
END = "// <<< PVE-MANAGER-STATUS: storcli_status <<<"


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
        for keyword in ("return", "typeof", "case", "delete", "void", "instanceof",
                        "in", "of", "new", "do", "else", "yield", "await"):
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

directory = os.path.dirname(path)
fd, tmp_path = tempfile.mkstemp(prefix=".pve-storcli-uninstall-", dir=directory)
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
    if [ $? -eq 0 ]; then
        changed=1
        echo "已删除 pvemanagerlib.js 注入 ✅"
    else
        echo -e "⛔ 删除 pvemanagerlib.js 注入失败, 正在回滚"
        [ -f "$js_tmp" ] && cp -a "$js_tmp" "$js_file"
    fi
    rm -f "$js_tmp"
fi

# 备份缺失时，用高度状态文件恢复基础高度
if [ "$restored_js" -eq 0 ] && [ -f "$js_file" ] && [ -f "$state_file" ]; then
    read -r base_h prev_inc < "$state_file" || true
    if [[ "$base_h" =~ ^[0-9]+$ ]]; then
        current_h=$(grep -A 40 "Ext.define('PVE.node.StatusView'" "$js_file" \
            | grep -m1 'height:' \
            | sed -E 's/[^0-9]//g')
        if [[ "$current_h" =~ ^[0-9]+$ ]] && [ "$current_h" -ne "$base_h" ]; then
            sed -i -E "/Ext[.]define[(]'PVE[.]node[.]StatusView'/,/height:/{s/height: *[0-9]+/height: ${base_h}/;}" "$js_file"
            changed=1
            echo "页面高度已恢复为安装前的 ${base_h}px ✅"
        fi
    fi
fi

# ==========================================
# 4. 删除自定义文件、缓存与权限
# ==========================================
echo -e "\n🗑️ 正在清理自定义文件:"

for file in "$parser_file" "$updater_file" "$sudoers_file" "$cache_file"; do
    if [ -e "$file" ]; then
        rm -f "$file" && echo "已删除: $file ✅"
        changed=1
    fi
done

if [ -d "$cache_dir" ]; then
    rmdir "$cache_dir" >/dev/null 2>&1 || true
fi

for dir in "$legacy_cache_dir" "$state_dir"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir" && echo "已删除目录: $dir ✅"
        changed=1
    fi
done

# ==========================================
# 5. 重启 PVE 服务
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
# 6. 完成
# ==========================================
echo -e "\n✅ 阵列卡 SMART 监控已卸载"

if [ "$changed" -eq 0 ]; then
    echo "未发现需要清理的安装痕迹 (可能已经卸载过) ➡️"
fi

if [ "$restored_nodes" -eq 0 ] || [ "$restored_js" -eq 0 ]; then
    echo -e "ℹ️ 部分文件未找到 .storcli.bak, 已使用兜底清理。"
    echo -e "   如仍不放心, 可执行: apt install --reinstall pve-manager pve-i18n"
fi

echo -e "\n♻️ 请使用 Ctrl + Shift + R 强制刷新浏览器缓存"
