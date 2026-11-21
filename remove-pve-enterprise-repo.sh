#!/bin/bash
# =====================================================================
# 移除 PVE 企业订阅源并修复 apt update
#
# 背景：
#   未购买 Proxmox VE 企业订阅时，enterprise.proxmox.com 会返回 401，
#   导致 apt-get update 报错：
#     E: Failed to fetch ... 401 Unauthorized
#
# 本脚本会：
#   1. 备份所有 apt 源文件
#   2. 注释/移除 enterprise.proxmox.com 的源
#   3. 确认存在 pve-no-subscription 源；没有则添加官方源
#   4. 执行 apt-get update 验证
#
# 用法：
#   bash remove-pve-enterprise-repo.sh
#
# 调试用环境变量：
#   PVE_APT_ETC      默认 /etc/apt
#   PVE_BACKUP_ROOT  默认 /var/backups/pve-manager-status
#   PVE_APT_GET      默认 apt-get
# =====================================================================

set -u

APT_ETC="${PVE_APT_ETC:-/etc/apt}"
SOURCES_LIST="${APT_ETC}/sources.list"
SOURCES_DIR="${APT_ETC}/sources.list.d"
BACKUP_ROOT="${PVE_BACKUP_ROOT:-/var/backups/pve-manager-status}"
APT_GET="${PVE_APT_GET:-apt-get}"

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/apt-enterprise-${STAMP}"

CODENAME=$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-trixie}" )

echo -e "\n🔧 移除 PVE 企业订阅源"
echo "   apt 配置目录: ${APT_ETC}"
echo "   Debian 代号 : ${CODENAME}"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    exit 1
fi

if ! command -v "$APT_GET" >/dev/null 2>&1; then
    echo -e "⛔ 未找到 ${APT_GET}"
    exit 1
fi

mkdir -p "$BACKUP_DIR" || {
    echo -e "⛔ 无法创建备份目录: ${BACKUP_DIR}"
    exit 1
}

echo -e "\n💾 备份目录: ${BACKUP_DIR}"

changed=0

backup_file() {
    local file="$1"
    local flat
    flat=$(printf '%s' "$file" | sed 's|^/||; s|/|_|g')
    if ! cp -a "$file" "${BACKUP_DIR}/${flat}" 2>/dev/null; then
        echo -e "⛔ 备份失败, 跳过修改: ${file}" >&2
        return 1
    fi
    return 0
}

comment_enterprise_lines() {
    local file="$1"
    local tmp_file
    tmp_file=$(mktemp /tmp/pve-enterprise-lines.XXXXXX) || return 1
    awk '{
        if ($0 ~ /enterprise\.proxmox\.com/ && $0 !~ /^[[:space:]]*#/) {
            print "# " $0
        } else {
            print $0
        }
    }' "$file" > "$tmp_file" && mv -f "$tmp_file" "$file"
    local rc=$?
    rm -f "$tmp_file"
    return $rc
}

# ==========================================
# 1. 处理 /etc/apt/sources.list
# ==========================================
if [ -f "$SOURCES_LIST" ] && grep -q '^[^#].*enterprise\.proxmox\.com' "$SOURCES_LIST" 2>/dev/null; then
    backup_file "$SOURCES_LIST" || exit 1
    comment_enterprise_lines "$SOURCES_LIST"
    changed=1
    echo "已注释 sources.list 中的企业订阅源 ✅"
fi

# ==========================================
# 2. 处理 /etc/apt/sources.list.d/
# ==========================================
if [ -d "$SOURCES_DIR" ]; then
    files=()
    while IFS= read -r file; do
        [ -n "$file" ] && files+=("$file")
    done < <(grep -RIl --include='*.list' --include='*.sources' \
        '^[^#].*enterprise\.proxmox\.com' "$SOURCES_DIR" 2>/dev/null)

    for file in "${files[@]:-}"; do
        [ -f "$file" ] || continue
        backup_file "$file" || continue

        case "$file" in
            *.sources)
                # deb822 格式：按空行分 stanza，只删除包含 enterprise 的 stanza
                tmp_file=$(mktemp /tmp/pve-enterprise.XXXXXX) || continue
                awk 'BEGIN { RS=""; ORS="\n\n" } !/enterprise\.proxmox\.com/' "$file" > "$tmp_file"
                if [ -s "$tmp_file" ] && grep -qi '^URIs:' "$tmp_file"; then
                    cat "$tmp_file" > "$file"
                    echo "已移除企业订阅 stanza: $file ✅"
                else
                    mv -f "$file" "${file}.disabled"
                    echo "已禁用企业订阅文件: $file -> ${file}.disabled ✅"
                fi
                rm -f "$tmp_file"
                ;;
            *)
                comment_enterprise_lines "$file"
                echo "已注释企业订阅行: $file ✅"
                ;;
        esac
        changed=1
    done
fi

if [ "$changed" -eq 0 ]; then
    echo -e "\nℹ️ 未发现企业订阅源, 可能已经移除过"
fi

# ==========================================
# 3. 确认 pve-no-subscription 源存在
# ==========================================
has_no_subscription=0
if [ -f "$SOURCES_LIST" ] && grep -q '^[^#].*pve-no-subscription' "$SOURCES_LIST" 2>/dev/null; then
    has_no_subscription=1
fi
if [ -d "$SOURCES_DIR" ]; then
    if grep -Rqs --include='*.list' --include='*.sources' \
        '^[^#].*pve-no-subscription' "$SOURCES_DIR" 2>/dev/null; then
        has_no_subscription=1
    fi
fi

if [ "$has_no_subscription" -eq 0 ]; then
    echo -e "\n⚠️ 未找到 pve-no-subscription 源, 正在添加官方源..."
    cat > "${SOURCES_DIR}/pve-no-subscription.list" <<EOF
deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription
EOF
    echo "已添加: ${SOURCES_DIR}/pve-no-subscription.list ✅"
else
    echo -e "\n✅ 已存在 pve-no-subscription 源"
fi

# ==========================================
# 4. 再次清理可能残留的 enterprise 引用
# ==========================================
leftover=0
if [ -f "$SOURCES_LIST" ] && grep -q '^[^#].*enterprise\.proxmox\.com' "$SOURCES_LIST" 2>/dev/null; then
    leftover=1
fi
if [ -d "$SOURCES_DIR" ] && grep -Rqs --include='*.list' --include='*.sources' \
    '^[^#].*enterprise\.proxmox\.com' "$SOURCES_DIR" 2>/dev/null; then
    leftover=1
fi

if [ "$leftover" -eq 1 ]; then
    echo -e "\n⚠️ 仍检测到 enterprise.proxmox.com 引用, 请手动检查:"
    echo "   ${SOURCES_LIST}"
    echo "   ${SOURCES_DIR}"
fi

# ==========================================
# 5. apt-get update 验证
# ==========================================
echo -e "\n🔄 正在执行 apt-get update:"

if "$APT_GET" update; then
    echo -e "\n✅ apt-get update 成功, 企业订阅源问题已修复"
    exit_code=0
else
    echo -e "\n⚠️ apt-get update 仍失败, 请检查上面的报错"
    exit_code=1
fi

echo -e "\n🧹 如需恢复本次修改:"
echo "   备份目录: ${BACKUP_DIR}"
echo "   sources.list: 复制备份覆盖回 ${SOURCES_LIST}"
echo "   *.sources/*.list: 将被注释/删除的内容恢复, 或把 .disabled 文件改回原名"

exit "$exit_code"
