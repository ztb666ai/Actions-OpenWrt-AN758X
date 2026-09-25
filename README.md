# PonWrt CI — Airoha AN758x PON 云编译

基于 P3TERX `Actions-OpenWrt` 模板重构，源码指向 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（默认分支 `master`），
针对 AN7581 / AN7583 PON 光猫做机型选择、磁盘释放与工具链缓存。

## 目录结构

```
.github/workflows/build-ponwrt.yml     主构建流程（机型可选 / 释放空间 / 工具链缓冲）
.github/workflows/cache-keepalive.yml  每 5 天 touch 缓存，防止被回收
diy-part1.sh    拉取可选插件到 package/custom（passwall/openclash/mosdns/lucky/tailscale 等，默认全关）
diy-part2.sh    把默认时区改成中国（Asia/Shanghai, CST-8）
configs/        每机型一份精简 diffconfig（约 440 行，需 make defconfig 展开）
files/          自定义 rootfs 文件，会自动拷进源码（sbin/tempinfo + 两个 uci-defaults）
packages/       CI 仓库自带的本地包（不走 clone），由 diy-part1.sh 拷进 package/custom
                ├─ luci-app-pon-status  PON 光模块卡片（概览页「系统」下一格）
                └─ luci-app-natmode     NAT 类型三选一（网络 → NAT 类型）
```

## diy 脚本

只有两个，职责单一：

### diy-part1.sh —— 拉插件

**默认开启**：

| 开关 | 包 | 作用 |
|------|-----|------|
| `ADD_AIROHA_NPU` | `luci-app-airoha-npu` | Airoha SoC 状态页：NPU 卸载 / CPU 频率与超频 / Frame Engine / PPE 流表 |

另外 CI 仓库自带两个本地包（`packages/`，不走 clone，由 diy-part1.sh 拷进 `package/custom`）：

| 包 | 作用 |
|-----|------|
| `luci-app-pon-status` | PON 光模块卡片：**温度 / 收光 / 发光 / 偏置电流 / 供电电压**，表格形式显示在概览页「系统」下一格 |
| `luci-app-natmode` | NAT 类型三选一：**全锥形 NAT1 / 受限型 NAT3 / 全对称型 NAT4**，菜单「网络 → NAT 类型」 |

> **已移除 `luci-app-temp-status`**：温度统一由 autocore 的 `/sbin/tempinfo`
> 提供（见下节），功能重叠，无需再装该插件。

其余默认关闭：`ADD_PASSWALL` / `ADD_OPENCLASH` / `ADD_MOSDNS` / `ADD_LUCKY` /
`ADD_TAILSCALE` / `ADD_OPENLIST` / `ADD_SMARTDNS`。

⚠️ 两点：
- 拉取目录名必须等于包名（`luci.mk: PKG_NAME ?= $(notdir ${CURDIR})`），
  改目录名会导致 config 里的符号对不上。
- 默认开启的 `luci-app-airoha-npu` 若拉取失败，脚本会 `::error::` 退出——否则 `defconfig`
  会静默剔除，编出缺状态页的固件还不易察觉。要关就把开关和 config 里的 `=y` 一起改。

中文情况：`luci-app-pon-status` 的文案写在 JS 里，已直接用中文。
`luci-app-airoha-npu` 用 luanmuc 版，**自带完整中文翻译**，见下节。

### luci-app-airoha-npu 的源与中文

**源仓库：`luanmuc/luci-app-airoha-npu`**（`rchen14b` 的 fork 改进版）：

| | rchen14b（原版）| luanmuc（本仓库选用）|
|---|---|---|
| 中文翻译 | ❌ po/ 只有 es + templates | ✅ 自带 `po/zh_Hans`，48 条全翻 |
| 仓库结构 | ⚠ 根目录 + 同名子目录各一份，feed 索引会中断 | ✅ 单层，正常 |
| luci.mk 路径 | 需 feeds 在固定位置 | ✅ 已修 |

config 里两个符号都开：

```
CONFIG_PACKAGE_luci-app-airoha-npu=y
CONFIG_PACKAGE_luci-i18n-airoha-npu-zh-cn=y
```

#### po 文件名必须改名（diy-part1.sh 已自动处理）

`luci.mk` 的 i18n install 规则：

```makefile
$(foreach po,$(wildcard ${CURDIR}/po/$(2)/*.po), \
	po2lmo $(po) $$(1)$(LUCI_LIBRARYDIR)/i18n/$(basename $(notdir $(po))).$(1).lmo;)
```

lmo 名取自 **po 文件主名**；而运行时按
`LUCI_BASENAME = $(patsubst luci-app-%,%,luci-app-airoha-npu)` = **`airoha-npu`** 查找。

上游两份 po 都叫 `luci-app-airoha-npu.po` → 生成 `luci-app-airoha-npu.zh-cn.lmo`
→ 前端要的是 `airoha-npu.zh-cn.lmo` → **找不到，中文不生效**。

官方 app 都是 basename 命名：`firewall.po`、`package-manager.po`、`pon.po`。
故 diy-part1.sh 在 clone 后把 `po/zh_Hans/*.po` 改名为 `airoha-npu.po`（幂等）。

## NAT 类型选择器（网络 → NAT 类型）

`packages/luci-app-natmode`（本地包）提供一个**三选一**界面，位置：
**网络 → NAT 类型**。

```
全锥形NAT（NAT1）      ← 推荐：游戏联机 / PT 做种 / PCDN
受限型NAT（NAT3）      ← 系统默认
全对称型NAT（NAT4）    ← 最严格，仅特殊合规场景
```

### 三档的实现原理

| 档位 | 实现 | 说明 |
|------|------|------|
| **全锥形 NAT1** | `firewall.@defaults[0].fullcone='1'` | fw4 生成 `fullcone` 表达式，内核 `kmod-nft-fullcone` 按转换后 3-tuple 建第二张哈希表，实现端点无关映射 + 端点无关过滤 |
| **受限型 NAT3** | `fullcone='0'`（netfilter 默认）| Linux `masquerade` 会尽量复用同一公网端口（EIM），入站只放行内网主动联系过的 IP:端口 → RFC 3489 的 Port Restricted Cone |
| **全对称型 NAT4** | `fullcone='0'` + 在各 `srcnat_*` 链首插入 `masquerade fully-random` | 每条新连接完全随机选源端口，映射不可预测，打洞基本失败 |

⚠️ 两点技术限制，如实说明：

1. **标准 netfilter 做不出精确的 NAT2**（仅地址受限、端口不受限）。
   它的过滤行为是「地址+端口都受限」，即 NAT3。所以本插件的「受限型」档位
   实测就是 NAT3，不是 NAT2。
2. **对称型用的是随机端口**，不是 RFC 定义的「按目的地独立映射」。
   两者对 P2P / STUN 的效果等同（都不可预测、都无法打洞），但严格语义不同。

### 文件结构

```
packages/luci-app-natmode/
├── Makefile
├── root/etc/config/natmode                        # UCI: natmode.main.mode
├── root/etc/init.d/natmode                        # START=25（晚于 firewall 的 19）
├── root/usr/sbin/natmode-apply                    # apply / status
├── root/usr/share/rpcd/acl.d/luci-app-natmode.json
├── root/usr/share/luci/menu.d/luci-app-natmode.json
└── htdocs/luci-static/resources/view/natmode/mode.js
```

### 与「网络 → 防火墙」选项的关系（重点）

**防火墙页面里那个「启用 FullCone NAT」和本插件是同一个 UCI 键。**

`luci-app-firewall` 的 `zones.js`：

```js
if (L.hasSystemFeature('fullcone')) {
    o = s.option(form.Flag, 'fullcone', _('Enable FullCone NAT'));
    ...
}
```

写的正是 `firewall.@defaults[0].fullcone`，与本插件操作的完全一致。

因此：

| 场景 | 结果 |
|------|------|
| 在本插件页切换 | 写 `natmode.main.mode` + `firewall` 的 fullcone，两边都同步 ✅ |
| 在防火墙页直接改 FullCone 开关 | **只改 `firewall`，`natmode.main.mode` 不变** → 本页显示与实际不符 ⚠️ |

针对第二种情况，`natmode-apply status` 会从实际 UCI / nftables 状态**反推生效模式**
（`effective` 字段），页面在两者不一致时给出黄色告警并提示重新保存同步。
所以不会出现"静默不一致"——差异一定会被看见。

> 补充：`L.hasSystemFeature('fullcone')` 的判定（luci-base 的 rpcd ucode 插件）是
> `access('/sys/module/nft_fullcone/refcnt')`，即**模块加载后**防火墙页才显示该选项。
> 存在"未开 fullcone → 模块没加载 → 选项不显示"的鸡生蛋情况；
> 本插件不依赖这个特性检测，始终可用。

### 与「路由/NAT 卸载」的相互影响（真实存在）

`zones.js` 里同一个 defaults 段还有 flow offload：

```js
o = s.option(form.RichListValue, "offloading_type", _("Flow offloading type"));
o.value('1', _("Software flow offloading"));
o.value('2', _("Hardware flow offloading"));
```

**fullcone 依赖 conntrack 的第二张哈希表，而 offload 会把已建立连接卸载到
快转路径绕过 conntrack** —— 两者同时开启时，走快转的流量可能不按 fullcone 行为处理，
实测 NAT 类型会不稳定或退化。对称型的 `fully-random` 同理。

本配置里 `kmod-nft-offload=y`（走 PPE 硬件转发），所以：
- **日常使用**：建议保持卸载开启（吞吐收益大），此时 NAT 类型可能测不准
- **要测/要稳定 NAT1**：临时把卸载关掉，或接受行为不严格一致

页面会读取 `firewall.@defaults[0].flow_offloading` 并在开启时给出提示。

### 不冲突的部分

- **端口转发 / DMZ**：fullcone 会接管 `dstnat` 链，但正常映射仍工作
  （DNAT 规则会被注入 fullcone 的 prerouting 路径），不会失效
- **UPnP**：独立机制（miniupnpd 写自己的 nft 规则），与 fullcone 无冲突，
  但注意 NAT1 场景下 UPnP 其实不必开（PCDN 客户端一般二选一即可）

### 两个易踩的坑（已处理）

- **启动顺序**：对称型插到 fw4 链里的 `fully-random` 规则，会被随后的
  `fw4 reload` 清掉。故 `init.d` 用 `START=25`（晚于 firewall 的 `START=19`），
  并挂了 `procd_add_reload_trigger firewall`，改防火墙后自动重新应用。
- **exec bit**：`luci.mk` 用 `$(CP)`（`cp -fpR`）复制 `root/`，保留源文件权限。
  若 git/zip 传输丢了 +x，rpcd 无法 exec、init.d 无法启动。
  diy-part1.sh 拷贝后统一 `chmod +x`，另有
  `files/etc/uci-defaults/97-natmode-perm` 开机兜底。
- **必须用 `form.Map`，不能用 `form.JSONMap`**（早期版本踩过）：

  `form.js` 里 `CBIJSONMap` 的实现是

  ```js
  __init__(data, ...args) {
      this.super('__init__', [ 'json', ...args ]);
      this.config = 'json';
      this.parsechain = [ 'json' ];
      this.data = new CBIJSONConfig(data);
  }
  ```

  第一个参数被当作 **JSON 数据对象**，不是文件名，且 `parsechain=['json']`，
  适用于 JSON 配置文件。**`/etc/config/natmode` 是标准 UCI 文件**，
  用 `JSONMap` 会导致解析失败、保存也写不回去 —— 必须用

  ```js
  var m = new form.Map('natmode', _('NAT 类型'), _('...'));
  ```

### 验证切换是否生效

页面顶部「当前状态」显示：当前模式、FullCone 开关、随机端口规则条数、
`nft_fullcone` 模块是否加载。

想看真实的 STUN 判定结果，可加装 `stun-client`（本仓库未默认编译）：

```sh
opkg install stun-client
stun-client stun.miwifi.com -v
# Independent Mapping, Independent Filter        → 全锥型 NAT1
# Independent Mapping, Address Dependent Filter  → 受限锥型 NAT2
# Independent Mapping, Port Dependent Filter     → 端口受限锥型 NAT3
# Dependent Mapping                              → 对称型 NAT4
```

## PON 光模块卡片（概览页系统下一格）

`packages/luci-app-pon-status`（本地包，非第三方 clone）在概览页新增
「PON 光模块」卡片，位置为**「系统」卡片的下一格**。

### 位置原理

`luci-mod-status` 的 `index.js`：

```js
fs.list('/www' + L.resource('view/status/include'))
  .filter(e => e.type=='file' && e.name.match(/\.js$/))
  .sort()                      // ← 按文件名字符串排序
  .map(n => L.require(n))
```

顺序即卡片顺序。官方默认：

```
10_system → 20_memory → 25_storage → 29_ports
          → 30_network → 40_dhcp → 50_dsl → 60_wifi
```

本包的文件名为 **`15_pon.js`**，落在 `10_system` 之后、`20_memory` 之前，
即系统卡片的紧邻下一格。

> 之前命名 `70_pon.js` 会排到 `60_wifi` 之后（页面最底部），改 `15` 即可上移。

### 显示内容

| 字段 | 来源字段 | 单位 |
|------|---------|------|
| 收光功率 | `rx_power_dbm` | dBm |
| 发光功率 | `tx_power_dbm` | dBm |
| 光模块温度 | `temperature_celsius` | °C |
| 偏置电流 | `tx_bias_ma` | mA |
| 供电电压 | `voltage_volts` | V |

换算由 `airoha-ponctl` 的 `convert_optics()` 完成（SFF-8472 → 显示单位）。

### 与温度行的关系

`files/sbin/tempinfo`（autocore）在概览「温度」行显示 `CPU / WiFi / PON` 三个温度。

**PON 温度会在两处出现** —— 温度行 + 本卡片。如需避免重复，把
`files/sbin/tempinfo` 里 `pon_temp` 的采集段注释掉即可（保留 CPU / WiFi）。

`tempinfo` 的 `SHOW_PON_OPTICS` 已设为 `0`，故温度行**不再**带光功率/电流/电压，
那些数值统一由本卡片展示，不会重复。


## 概览页「温度」一栏

别的 AN758x 固件概览页有「温度：CPU 58.7°C, WiFi 46.0°C」这一行，ponwrt 原生没有。
原因是**这一行不是插件提供的，而是 autocore 的一个条件安装文件**：

### 机制

```
luci-mod-status 的 10_system.js
  → callTempInfo()  → rpcd: luci.getTempInfo  → 执行 /sbin/tempinfo
  → 输出非空则 fields.splice 插入「温度」行
```

`10_system.js` 里的判断就是 `if (tempinfo.tempinfo)`，即 `/sbin/tempinfo` 有输出才显示。

### 为什么 ponwrt 没有

autocore 的 Makefile：

```makefile
ifneq ($(filter ipq% mediatek% qualcommax%, $(TARGETID)),)
	$(INSTALL_BIN) ./files/tempinfo $(1)/sbin/
endif
```

只对 `ipq*` / `mediatek*` / `qualcommax*` 安装 `tempinfo`。
**airoha（AN7581/AN7583）不在列表里**，所以 ponwrt 编出来的固件没有 `/sbin/tempinfo`，
概览页也就没有温度行。（ponwrt 自己 `package/emortal/autocore` 也是这份 Makefile，未做适配。）

### 本仓库的解决方式

直接放一份 `files/sbin/tempinfo` 覆盖进 rootfs（autocore 在 airoha 上不装同名文件，不冲突）：

- **CPU**：`/sys/class/thermal/thermal_zone0/temp`
- **WiFi**：mt76 的 hwmon，`phy*/hwmon*/temp1_input` 和
  `phy*/device/hwmon/hwmon*/temp1_input` 两个路径都试（mt76 两种挂法都见过）
- **PON**：`ponctl --device <dev> status --json` + `jsonfilter`，
  取 `frontend` 组的 `temperature_celsius` / `rx_power_dbm` / `tx_power_dbm` /
  `tx_bias_ma` / `voltage_volts`（airoha-ponctl 的 `convert_optics()` 已换算成显示单位）

输出示例：

```
CPU: 58.7°C, WiFi: 46.0°C 48.0°C, PON: 48.5°C ↑2.41dBm ↓-21.30dBm 12.50mA 3.30V
```

授权不需要额外处理 —— autocore 装的
`/usr/share/rpcd/acl.d/luci-mod-status-autocore.json` **无条件**授权 `luci.getTempInfo`
（只有 tempinfo 脚本本身受平台限制）。所以只要 `autocore=y` + `luci-base=y` 就通。

### 疑难排查：温度显示 "?"

`luci-base` 的 rpcd ucode 插件（`root/usr/share/rpcd/ucode/luci`）：

```ucode
getTempInfo: {
    call: function() {
        if (!access('/sbin/tempinfo')) return {};   // access = F_OK，只验证存在
        const fd = popen('/sbin/tempinfo');
        let tempinfo = fd.read('all');
        if (!tempinfo) tempinfo = '?';              // 空输出 → '?'
        return { tempinfo: tempinfo };
    }
}
```

| 症状 | 原因 |
|------|------|
| 温度行**不显示** | `/sbin/tempinfo` 不存在（插件 `return {}`）|
| 温度行显示 **?** | 文件存在但**缺 +x** → `popen` 失败 → stdout 空 |

`access()` 是 F_OK，只看存在不看可执行，所以权限问题会走到 popen 分支变成 `?`。

本仓库两道保险：

1. workflow 第 6 步 `chmod +x files/sbin/*`（git checkout 可能丢 exec bit）
2. `files/etc/uci-defaults/98-tempinfo-perm` 首次开机再补一次

uci-defaults 由 `/etc/init.d/boot` 以 source 方式执行（`. "$i"`），自身不需 +x，
即使打包时权限再丢也能救回来。返回 0 后被自动删除。

已刷机的设备直接 `chmod +x /sbin/tempinfo` 即可，刷新页面生效，无需重启 rpcd。

### 开关：SHOW_PON_OPTICS

`tempinfo` 顶部有一个开关：

```sh
SHOW_PON_OPTICS=1    # 温度行附带 PON 光功率/电流/电压
SHOW_PON_OPTICS=0    # 只显示温度（CPU / WiFi / PON）
```

设为 `0` 时输出：`CPU: 58.7°C, WiFi: 46.0°C 48.0°C, PON: 48.5°C`

本仓库**默认设为 `0`**，因为 `luci-app-pon-status` 卡片已用表格形式完整展示
收发光/电流/电压，两者会重复。若你想只要一行、不装 pon-status 卡片，改回 `1` 即可。

⚠️ 取舍：`SHOW_PON_OPTICS=1` 会把 dBm / mA / V 塞进标题为「温度」的一行，语义不严谨且行较长。

### 与 luci-app-temp-status 的关系

**已移除该插件**，两者功能重叠：

| | autocore tempinfo | luci-app-temp-status |
|---|---|---|
| CPU 温度 | ✅ | ✅ |
| WiFi 温度 | ✅ | ✅ |
| PON 温度/光功率 | ✅（本仓库扩展）| ❌ |
| 依赖 | 仅 shell + autocore + ponctl | `ucode` + `ucode-mod-fs` |

保留 autocore 方案：它是 ImmortalWrt 原生机制，无额外依赖，且能顺带扩展 PON。
移除后也省掉了 `ucode-mod-fs` 等间接项的体积（虽小）。

依赖：`airoha-ponctl`（`ponctl`）、`jsonfilter`、`uci` —— 配置里均已 `=y`。
脚本对三者都做了 `-x` 存在性检查，缺任一则自动跳过 PON 段，不影响 CPU/WiFi 显示。

### 一点开销说明

概览页轮询间隔 3 秒，故 `tempinfo` 每 3 秒执行一次 `ponctl`。
`ponctl` 是 Rust 二进制、只读 sysfs，开销可忽略。
但注意 `luci-app-pon-status` 卡片同样每 3 秒调一次 `ponctl`，
两者叠加即约每 1.5 秒一次 `ponctl` 调用 —— 若在意，把 `SHOW_PON_OPTICS` 设 `0` 即可减半。

## Release 行为

- 只有 `scope=firmware` 且编译成功才发 Release；`toolchain-only` 不发。
- 空固件目录会跳过，不会发空 Release。
- `fail_on_unmatched_files: false`：机型产物后缀不同（`*.itb` / `*.ubi` / `*.bin` / `*.manifest` 等），缺哪种都不会让这一步失败。
- 自动清理：每个机型的 Release 只保留最近 10 个（`delete_tag_pattern: ^<DEVICE_NAME>-`，不会误删 `toolchain-cache`）。
- 关掉 Release 只留 Artifact：把 `upload_release` 选 `false`，或把 env 里 `UPLOAD_RELEASE` 默认值改成 `'false'`。

> 首次运行建议先 `scope=toolchain-only`（不产固件、不发 Release）把工具链缓存建起来，再跑 `firmware`。

## 支持的机型

| SoC | profile |
|-----|---------|
| AN7581 | `fiberhome_hg5382a` `fiberhome_hg5585f-ct` `fiberhome_hg5585f-cu` `gemtek_xg2010g` `nokia_xg-040g-md-ubi` `nokia_xg-040g-tf-ubi` `unionman_ung00a` `znxt_zn504xg-d` `znxt_zn515xg-d` |
| AN7583 | `nokia_xg-040g-mf` `nokia_xg-040g-mf-ubi` |

机型名写错会在 `Generate toolchain cache key` 步骤直接报 `::error::` 并退出，不会静默地全机型编译。

## 工具链缓存机制

- Key：`ponwrt-toolchain-<board>-<subtarget>-<tools/toolchain 源码 md5 前 16 位>`，源码工具链一变就失效重编。
- 命中顺序：`actions/cache` → 仓库 `toolchain-cache` Release 备份 → 本地编译。
- Release 命中后会回写 `actions/cache`，下次构建走快通道。
- 命中缓存时用 `sed -i 's/ $(tool.*\/stamp-compile)//' Makefile` 跳过工具链重编。
  （对 ponwrt 根 Makefile 确实命中第 46 / 47 / 130 行，去掉 `$(tools/stamp-compile)`、
  `$(toolchain/stamp-compile)` 依赖。）
- 额外缓存：`.ccache`（编译缓存）、`dl`（软件包下载目录）。

### 缓存 key 的滚动周期

`dl` 与 `ccache` 的 key 都用**年+周号**（`$(date +%Y%W)`，如 `202639`），由
`Resolve device profile` 步骤的 `week` output 提供。

| 缓存 | key |
|------|-----|
| dl | `ponwrt-dl-<branch>-<week>` |
| ccache | `ponwrt-ccache-<soc>-<week>` |

原因是这两个缓存**体积大且会每次 save**：

- 若用 `github.run_id` / `github.run_number`，每次运行都会生成一份新副本，
  10GB 配额很快被刷满，并淘汰掉真正有用的旧缓存；
- 改成周号后，同一周内多次运行复用同一条目，`restore-keys` 仍能跨周命中。

### ccache：默认关闭，按需开启

ccache 默认**关闭**（`USE_CCACHE: false`，config 里也不写 `CONFIG_CCACHE`）。
原因是一个真实的缓存一致性陷阱：

`tools/Makefile`：

```makefile
ifneq ($(CONFIG_CCACHE)$(CONFIG_SDK),)
  tools-y += ccache xxhash
endif
```

即 **ccache 二进制只在 `CONFIG_CCACHE` 生效时才由 `make tools/install` 编入**
`staging_dir/host/bin`。而 `rules.mk`：

```makefile
ifneq ($(CONFIG_CCACHE),)
  TARGET_CC:= ccache $(TARGET_CC)
  export CCACHE_DIR:=$(TOPDIR)/.ccache
endif
```

于是出现这种失败：

| 时序 | 结果 |
|------|------|
| 工具链缓存是**未开 ccache** 时建立的 | 缓存里没有 `staging_dir/host/bin/ccache` |
| 之后开启 `CONFIG_CCACHE=y` + 缓存命中 | `make tools/install` 被跳过 → ccache 没被补装 |
| 编译任何包 | `/bin/sh: 1: .../staging_dir/host/bin/ccache: not found`（**Error 127**）|

要开启 ccache，**只改一处**：workflow 的 `USE_CCACHE: true`。
流程里「Setup ccache (opt-in)」步骤会：

1. 自动往 `.config` 追加 `CONFIG_CCACHE=y` 并 `make defconfig`；
2. 检测 `staging_dir/host/bin/ccache`，缺失就 `make tools/ccache/install` 补装
   （ccache 依赖 `xxhash` → `cmake`，首次会多花几分钟）；
3. 补装失败则自动把 `CONFIG_CCACHE` 改回 `is not set` 并继续编译 ——
   **绝不会因为 ccache 让整次构建失败**。

> 提醒：开启后 `.ccache` 会额外占用磁盘，注意 runner 剩余空间。

## 首次使用建议

免费 runner 单次上限 6 小时，首次全量编译（工具链 + 内核 + 全包）大概率超时：

1. 先跑一次 `scope = toolchain-only`，把工具链缓存建起来；
2. 再跑一次 `scope = firmware` 出固件；
3. 若仍超时，把 `configs/*.config` 里不需要的 luci-app / 语言包删掉再提交。

## 注意事项

- 刷机前用 [AN758x-Stock2UBI](https://github.com/pbs05) 备份原厂 flash；烽火 `factory` 备份需先过 `FiberHome Factory` 转换。
- 刷完后通过 U-Boot Web 或 LuCI → 网络 → PON → Configuration → PON board data 恢复校准/身份数据，否则 WiFi 与 PON  Registration 异常。
- `toolchain-cache` Release 由流程自动维护，`Remove old releases` 用 `delete_tag_pattern: ^<DEVICE_NAME>-` 限定，不会误删。
