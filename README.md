å# PVE-Manager-Status
为你的 ProxmoxVE 节点概要页面添加扩展的硬件监控信息

无论是小型 HomeLab 还是多节点的大型集群, 借助 PVE-Manager-Status 让你对当前服务器硬件状态了如指掌!

PVE-Manager-Status 是一款强大的开源脚本工具, 通过实时基于动态色彩的关键指标显示, 帮助你直观的了解服务器各项硬件的负载和温度, 从而轻松掌握设备的实时运行状态以确保其稳定高效.

## 说明与致谢

本项目 Fork 自 [MiKing233/PVE-Manager-Status](https://github.com/MiKing233/PVE-Manager-Status)，感谢原作者 **MiKing233** 以及所有贡献者提供的优秀基础项目。

本 Fork 沿用上游项目的脚本结构、安装方式与大部分硬件监控功能，并在此基础上主要增加了：

- **LSI / Broadcom MegaRAID 阵列卡物理硬盘 SMART 监控**：显示型号、温度、通电时间、坏道、健康状态、无法纠错数、序列号、生产日期、累计读写量；
- **节点概要页面动态高度计算**：修复阵列卡虚拟盘导致页面底部大面积留白的问题；
- **SMART 解析结果缓存**：避免 PVE 页面每次刷新都频繁唤醒阵列卡下的 SAS 硬盘。

本 Fork 并非上游官方发布版本，新增的阵列卡功能由本仓库维护。本仓库与原项目均遵循 MIT License，使用前请阅读下方的免责声明，并先在测试环境中充分验证。

<img width="1120" height="699" alt="image" src="https://github.com/user-attachments/assets/51224701-a763-4b14-9951-5990f7e22901" />
<img width="1899" height="2355" alt="pve08-Proxmox-Virtual-Environment-11-21-2026_10_17_PM" src="https://github.com/user-attachments/assets/ef0d678d-dca0-4d2b-9a76-0551a1834298" />


## 免责声明

在任何正式或关键的生产环境中, 未经完整测试与评估, 严禁直接部署和运行本工具. 在使用本工具之前, 务必对代码进行详尽的审阅, 充分理解其运行机制, 使用该工具后的风险由您自行承担.

## 包含的功能

- 为 ProxmoxVE Web 管理界面的节点概要中添加各项硬件的实时监控信息.
- 根据各项硬件的温度和负载, 使用红黄绿色从高到低来显示各项参数的数值.
- 支持识别多块 NVMe 硬盘, 并根据寿命和压力负载显示动态色彩指标.
- 完善 zh-CN 本地化, 修复中文环境下缺失的部分翻译.
- **[本 Fork] 支持 LSI / Broadcom MegaRAID 阵列卡物理硬盘 SMART 监控**, 可显示型号、温度、通电时间、坏道、健康状态、无法纠错数、序列号、生产日期、累计读写量、SSD 寿命与不安全断电次数.
- **[本 Fork] 节点概要页面高度动态计算**: 基础内容按 PVE 实际行高 17px + 2px/模块分隔线计算, 传感器按 Package 数与核心数统计; 阵列卡硬盘按 51px/块追加; 重复执行不会重复累加.
- **[本 Fork] systemd timer 每 5 分钟后台刷新阵列卡 SMART 缓存**, PVE 页面只读取缓存文件, 页面请求中不执行任何 smartctl/耗时命令.

## 如何使用

现在只需要记住一个入口脚本 `pve-manager-status.sh`, 直接运行会打开交互式菜单:

```text
1) 一键安装/更新: 基础监控 + 阵列卡监控  (推荐)
2) 仅安装/更新:   基础监控
3) 仅安装/更新:   阵列卡监控
4) 卸载阵列卡监控 (保留基础监控)
5) 完整恢复 PVE 原始状态 (清除所有修改)
6) 查看当前状态
7) 立即刷新阵列卡缓存
8) 移除 PVE 企业订阅源 (修复 apt update)
0) 退出
```

也可以直接用参数执行, 便于自动化:

```bash
git clone https://github.com/qing121171-blip/PVE-Manager-Status.git
cd PVE-Manager-Status

# 一键安装: 基础硬件监控 + 阵列卡 SMART 监控
bash pve-manager-status.sh install

# 非交互安装 (跳过确认)
bash pve-manager-status.sh install --yes
```

也可以分步执行:

```bash
# 只安装/重装基础硬件监控 + 动态高度
bash pve-manager-status.sh base

# 只安装阵列卡 SMART 监控 (需要先执行 base)
bash pve-manager-status.sh storcli-install
```

常用命令:

```bash
bash pve-manager-status.sh status           # 查看安装/缓存/定时器状态
bash pve-manager-status.sh update-cache     # 立即刷新阵列卡缓存
bash pve-manager-status.sh storcli-uninstall # 只卸载阵列卡监控
bash pve-manager-status.sh restore          # 完整恢复 PVE 原始状态
bash pve-manager-status.sh repo-fix         # 移除企业订阅源, 修复 apt update 401
bash pve-manager-status.sh help             # 查看帮助
```

安装完成后, 使用 `Ctrl + Shift + R` 强制刷新浏览器 Proxmox VE Web 管理页面缓存.

脚本说明:

- `pve-manager-status.sh`: 统一入口 + 基础硬件监控 + 页面高度模型.
- `install-storcli-monitor.sh`: 阵列卡监控安装模块（供统一入口调用）.
- `uninstall-storcli-monitor.sh`: 阵列卡监控卸载模块.
- `restore-pve-original.sh`: 完整恢复 PVE 原始文件（不依赖 .bak，适合多次运行后备份已被污染的情况）.
- `remove-pve-enterprise-repo.sh`: 移除 PVE 企业订阅源，修复未订阅环境下 `apt-get update` 的 401 错误.
- `add-storcli-monitor.sh`: 旧入口, 已改为转调安装模块, 保留兼容.

> [!IMPORTANT]
> `pve-manager-status.sh` 的基础安装会重装 `pve-manager` / `pve-i18n`, 这会清掉阵列卡注入.
> 直接使用 `bash pve-manager-status.sh install` 会自动完成“基础 + 阵列卡”两步；
> 如果只执行了 `base`, 需要再执行 `bash pve-manager-status.sh storcli-install`.

阵列卡监控的前置条件:

- Proxmox VE 8 / 9 (本 Fork 在 PVE 9.2.31 上实测)
- LSI / Broadcom MegaRAID 阵列卡 (`megaraid_sas`), 且 `smartctl -a -d megaraid,<DID> /dev/bus/<N>` 能读取物理盘
- 已安装 `smartmontools` 与 `python3`
- 以 root 身份执行

部署前可先用 `smartctl --scan | grep megaraid` 确认阵列卡物理盘能被识别.

如果你只需要上游原版功能 (不含阵列卡监控), 可以继续使用:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MiKing233/PVE-Manager-Status/main/pve-manager-status.sh)"
```

> [!WARNING]
> 若此时可以看到 PVE-Manager-Status 带来的扩展硬件监控信息, 但无法看到风扇转速信息, 这代表 sensors 命令输出中不包含风扇转速信息, 你可能需要安装额外的传感器驱动包. 不同厂商不同设备间使用的接口都可能有所不同, 在此无法一概而论.

对于使用 IT87 系列传感器的设备, 使用以下命令安装传感器驱动包 it87-dkms_1.0.63-1_all.deb

```
wget -O /root/it87-dkms_1.0.63-1_all.deb https://raw.githubusercontent.com/MiKing233/PVE-Manager-Status/main/it87-dkms_1.0.63-1_all.deb && apt install /root/it87-dkms_1.0.63-1_all.deb && rm -f /root/it87-dkms_1.0.63-1_all.deb
```

安装完成后, 重启系统并再次检查风扇转速信息.

## 阵列卡 SMART 监控（本 Fork 新增）

`install-storcli-monitor.sh` 负责把 MegaRAID 阵列卡下的物理硬盘信息接入 PVE 节点概要页面, 采用 **systemd timer + 文件缓存** 架构:

| 项目 | 说明 |
| --- | --- |
| 数据读取 | `smartctl -a -d megaraid,<DID> /dev/bus/<N>`, 绕过阵列卡直接读取物理盘 SMART |
| 解析器 | `/usr/local/bin/pve_storcli_parser.py`, 每块盘输出 12 个字段, 多块盘以双竖线分隔 |
| 缓存更新器 | `/usr/local/bin/pve_storcli_cache_updater.sh`, 调用解析器并原子写入缓存 |
| 定时器 | `pve-storcli-cache.timer`, `OnBootSec=1min` + `OnUnitActiveSec=5min` |
| 权限 | `/etc/sudoers.d/pve-storcli`, 允许 `www-data` 免密执行 `smartctl` 与解析器 |
| 后端注入 | `Nodes.pm` 中在 `$res->{sata_status}` 后注入 `$res->{storcli_status}`, 只读取缓存文件 |
| 前端注入 | `pvemanagerlib.js` 中在 `sata_status` 模块后注入阵列卡渲染模块 |
| 页面高度 | 读取 Fork 版算出的基础高度, 再按 **51px/块盘** 追加; 5 块盘增加 255px |
| 结果缓存 | `/var/cache/pve-manager/storcli_status.cache`, timer 每 5 分钟刷新 |

脚本结束时会执行一次初始缓存生成, 启用 `pve-storcli-cache.timer`, 并重启 `pvedaemon` 与 `pveproxy`.

### 定时缓存架构

```text
systemd timer (每 5 分钟)
  -> pve_storcli_cache_updater.sh
  -> pve_storcli_parser.py --refresh
  -> /var/cache/pve-manager/storcli_status.cache
  -> Nodes.pm 只读取缓存文件
  -> pvemanagerlib.js 渲染
```

PVE 页面请求 `Nodes.pm` 时不再执行 `smartctl`，因此不会因为阵列卡或 SAS 盘唤醒而卡顿。

手动刷新缓存:

```bash
systemctl start pve-storcli-cache.service
# 或直接执行
/usr/local/bin/pve_storcli_cache_updater.sh
```

查看定时器:

```bash
systemctl list-timers pve-storcli-cache.timer
```

解析器字段顺序: `型号|温度|通电时间|坏道|健康状态|无法纠错数|序列号|生产日期|读取GB|写入GB|不安全断电|寿命`

监控字段 (每块盘 3 行):

- 第 1 行: 型号 | 温度 | 通电时间 | 健康状态
- 第 2 行: SN | 生产日期 | 坏道 | 无法纠错数
- 第 3 行: 寿命 | 不安全断电次数 | 累计读取量 | 累计写入量

显示规则:

- 配色与 NVMe 硬盘模块保持一致: 标签文字使用默认颜色, 仅型号/温度/寿命/坏道等关键数值着色.
- 温度低于 50°C 显示绿色, 50–69°C 显示橙色, 70°C 及以上显示红色.
- 坏道数为 0 显示绿色, 非 0 显示橙色; 无法纠错数非 0 显示红色.
- SSD 寿命 ≥80% 显示绿色, 50–79% 显示橙色, <50% 显示红色; 不安全断电次数与 NVMe 模块一样使用普通文本, 不高亮.
- HDD 的型号按健康状态着色; 没有寿命/断电统计时对应字段自动隐藏, 只显示读写量.
- 读取/写入量自动换算为 GB / TB / PB.
- 生产日期统一为 `Wxx yyyy` 格式 (例如 `W45 2016`). SAS 盘直接读取 smartctl 的出厂周; Intel SATA SSD 的 smartctl 不提供出厂日期, 解析器会从 ISN/SN 第 5 位年份和第 6-7 位周数推导.
- SSD 寿命取自 SMART 属性的归一化 VALUE 列 (例如 Intel `Media_Wearout_Indicator` 的 `099` 显示为 `99%`); 不安全断电次数取自 `Unsafe_Shutdown_Count` 的 RAW_VALUE.
- 解析器会强制以英文 locale 读取 `smartctl` 输出, 避免中文环境下的字段匹配失败.

### 高度说明

- `pve-manager-status.sh` 使用 **17px/行 + 2px/模块分隔线** 计算基础高度; 传感器按实际 `Package` 数与每 4 个核心 1 行统计, 避免多路 CPU 少算行数.
- PVE 9 中 `pveNodeStatus` 的 body 高度 = 面板高度 - 46px (标题栏 + 内边距), 且 body 内部还有 20px 上下 padding; 当前模型额外预留 20px, 让 body 内容区略大于 table, 避免最后一行被裁切.
- 已修正上游 `sata_status` 按 `lsblk` 统计阵列卡虚拟盘导致的高度冗余: 阵列卡虚拟盘读不到底层 SMART 时只按 1 行提示计算.
- `install-storcli-monitor.sh` 在基础高度上追加 `硬盘数 * 51px`, 并把基础高度与增量记录在 `/var/lib/pve-manager-status/storcli-height.state`.
- 重复执行不会重复累加; 重跑主脚本后会以新的基础高度重新计算.
- 如果浏览器缩放或字体导致仍然留白/溢出, 可调整 `install-storcli-monitor.sh` 顶部的 `disk_height=51`.
- 也可以临时用环境变量覆盖: `PVE_STORCLI_DISK_HEIGHT=44 bash install-storcli-monitor.sh` (默认 51).

### 一键卸载 / 回滚

安装时会生成:

- `/usr/share/perl5/PVE/API2/Nodes.pm.storcli.bak`
- `/usr/share/pve-manager/js/pvemanagerlib.js.storcli.bak`

卸载只需执行:

```bash
bash pve-manager-status.sh storcli-uninstall
# 或直接执行模块
bash uninstall-storcli-monitor.sh
```

卸载脚本会自动完成:

- 停止并删除 `pve-storcli-cache.timer` / `pve-storcli-cache.service`
- 删除解析器、缓存更新器、sudoers、缓存文件与高度状态
- 从 `.storcli.bak` 还原 `Nodes.pm` 与 `pvemanagerlib.js`
- 备份缺失时, 退化为精确删除注入代码并把页面高度恢复到安装前
- 重启 `pvedaemon` / `pveproxy`

脚本可重复执行, 不会因为文件已不存在而报错.

> 注意: `pve-manager-status.sh` 重跑时会清理 `*.bak`, 之后重新执行 `install-storcli-monitor.sh` 会生成新的干净备份.

### 完整恢复原始 PVE（多次运行后 .bak 失效时）

早期 `pve-manager-status.sh` 的顺序是“先备份当前文件，再重装软件包”。多次运行后，`.bak` 备份到的是上一次修改后的文件，而不是真正的原始文件，因此无法再靠 `.bak` 回滚。

当前版本已调整为先重装、再备份、最后修改，新生成的 `.bak` 是干净的。对于已经被污染的环境，执行：

```bash
bash pve-manager-status.sh restore
# 或非交互
bash pve-manager-status.sh restore --yes
```

它会：

- 停止并删除 storcli timer/service、解析器、缓存更新器、sudoers、缓存与高度状态
- 删除 `/etc/sudoers.d/pve-manager-status`
- 删除 `/etc/modules-load.d/turbostat-msr.conf`
- 通过 `apt-get install --reinstall -y pve-manager pve-i18n` 从软件包恢复原始 `Nodes.pm` / `pvemanagerlib.js` / `pve-lang-zh_CN.js`
- 删除所有旧 `.bak`，避免以后误用被污染的备份
- 校验是否还有注入残留
- 重启 `pvedaemon` / `pveproxy`

> 依赖包（sudo/sysstat/lm-sensors/smartmontools/linux-cpupower）、`it87-dkms` 以及 `/etc/modules` 中 sensors-detect 追加的模块不会自动卸载；脚本结束时会提示，需自行确认后处理。

### 修复 apt update：移除企业订阅源

未购买 PVE 企业订阅时，`enterprise.proxmox.com` 会返回 401，导致：

```text
E: Failed to fetch https://enterprise.proxmox.com/debian/pve/dists/trixie/InRelease 401 Unauthorized
```

执行：

```bash
bash pve-manager-status.sh repo-fix
```

或在交互式菜单选择 `8`。

脚本会：

- 备份 `/etc/apt/sources.list` 与 `/etc/apt/sources.list.d/` 下相关文件
- 注释或移除 `enterprise.proxmox.com` 源
- 确认存在 `pve-no-subscription` 源；没有则添加官方源
- 执行 `apt-get update` 验证

备份目录：`/var/backups/pve-manager-status/apt-enterprise-<时间戳>/`

## 已知问题

- 阵列卡监控目前只针对 LSI / Broadcom MegaRAID (`megaraid_sas`) 验证通过. 其他 RAID/HBA (例如 `-d sat`, `-d scsi`, `-d areca`) 需要自行调整解析器中的 `-d megaraid,<DID>` 读取方式.
- 安装器会检查 `storcli64`/`storcli` 是否存在, 但实际读取使用 `smartctl`; 未安装 storcli 也可以运行, 只会在安装时给出提示.
- `51px/块盘` 是在特定浏览器缩放和字体下的实测值. 如果页面仍有留白或内容被截断, 请调整 `install-storcli-monitor.sh` 顶部的 `disk_height`.
- 阵列卡数据默认最多有 5 分钟缓存延迟; 需要立即刷新时执行 `systemctl start pve-storcli-cache.service`.
- 上游的直连 SATA 硬盘监控代码未经过完整测试; 本 Fork 的阵列卡物理盘监控走独立的 `storcli_status` 模块, 不依赖该逻辑.
- nvme 硬盘监控部分对于 I/O 实时读写速度和延迟的实现代码使用目前常见的 iostat -d -x -k 1 1 但这将导致长时间运行后 iostat 进程休眠或被杀死, 你将会看到这部分监控参数"冻结", 在重启前将永远不再刷新, 目前尝试过使用其它方式实现这个功能避免冻结, 但都未能达到预期的效果, 有些实现方式复杂超出预期短期内无法解决, 另外一些能生效的方法则不够优雅, 会导致Web页面自动刷新间隔变得非常长.
- 执行 `apt upgrade` 升级 `pve-manager` 后, 本项目的 Perl/JS 注入可能被覆盖. 重新执行 `pve-manager-status.sh` 和 `install-storcli-monitor.sh` 即可恢复.

## 未来计划

- 修复长时间运行 nvme 硬盘监控部分 I/O读写延迟冻结的问题.
- 适配更多 RAID/HBA 控制器, 并支持自定义 `smartctl -d` 类型.

## 相容性

- 适用基于 Debian 12 "bookworm" 的 Proxmox VE 8 与基于 Debian 13 "trixie" 的 Proxmox VE 9.
- 本 Fork 的阵列卡功能在 **PVE 9.2.31 + Broadcom / LSI MegaRAID SAS-3 3108 (PRAID EP400i) + 1 块 SATA SSD + 4 块 SAS HDD** 环境下实测通过; PVE 8 环境尚未逐项验证.
- 针对 Proxmox VE 7 等旧版环境之可用性未经实际测试, 请谨慎使用本项目. 您需要在拥有root权限的节点上运行该工具执行修改.
- 在将本项目用于实际环境前, 务必先在测试环境进行测试, 若修改后遇到问题请通过下面的命令重装相关软件包以恢复被修改的文件至默认配置.
```
apt install --reinstall pve-manager pve-i18n
```

## 贡献

欢迎您的贡献! 如果您有任何改进或调整, 请 Fork 代码库并提交拉取请求.

## 联系与反馈

如果您遇到任何问题或有任何建议, 请在 GitHub 代码库中提交问题.

## 致谢

感谢以下来源和社区贡献, 本项目的诞生离不开源自这些来源和贡献:

- https://github.com/a1wong/it87
- https://github.com/shidahuilang/pve
- https://github.com/xiangfeidexiaohuo/pve-diy
- https://bbs.x86pi.com/thread?topicId=20
- https://community-scripts.github.io/ProxmoxVE
- https://github.com/community-scripts/ProxmoxVE
- https://github.com/proxmox/pve-manager
- https://github.com/Debian

## 贡献者

<a href="https://github.com/MiKing233/PVE-Manager-Status/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=MiKing233/PVE-Manager-Status" />
</a>

## 许可证

本项目为开源项目, 遵循 MIT License.

这些代码按"原样"提供, 不提供任何担保, 也不授予任何权利. 您有责任安全地使用本工具, 并遵守软件许可协议的条款.

## 请我喝杯咖啡

捐赠是本项目唯一的收入来源, 如果您愿意支持这个项目, 这将帮助该项目走得更远! 感谢您的支持!
- https://donate.mknetwork.net

### 如果你喜欢这个项目, 请不要吝啬您的 Star 🌟
[![Star History Chart](https://api.star-history.com/chart?repos=miking233/pve-manager-status&type=date&legend=bottom-right)](https://www.star-history.com/?repos=miking233%2Fpve-manager-status&type=date&releases=&legend=bottom-right)

Enjoy a better Proxmox VE experience!
