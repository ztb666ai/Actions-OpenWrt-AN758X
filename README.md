# PonWrt CI — Airoha AN758x PON 云编译

基于 P3TERX `Actions-OpenWrt` 模板重构，源码指向 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（默认分支 `master`），
针对 AN7581 / AN7583 PON 光猫做机型选择、磁盘释放与工具链缓存。

### diy-part1.sh —— 拉插件

**默认开启**：

| 开关 | 包 | 作用 |
|------|-----|------|
| `ADD_AIROHA_NPU` | `luci-app-airoha-npu` | Airoha SoC 状态页：NPU 卸载 / CPU 频率与超频 / Frame Engine / PPE 流表 |
其余默认关闭：`ADD_PASSWALL` / `ADD_OPENCLASH` / `ADD_MOSDNS` / `ADD_LUCKY` /
`ADD_TAILSCALE` / `ADD_OPENLIST` / `ADD_SMARTDNS`。

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

## NPU 固件

NPU 是 Airoha SoC 里那颗 RISC-V 核，**不是** Linux 驱动 —— host 端驱动 `airoha_npu`
随内核编出，它按固定名字找两个固件镜像：

| 镜像 | 默认文件名 | 上限 | 加载去向 |
|---|---|---|---|
| rv32（text+rodata） | `airoha/en7581_npu_rv32.bin`（AN7583 为 `an7583_*`） | 2 MiB | `npu_binary` @0x84000000 |
| data（.data） | `airoha/en7581_npu_data.bin` | 64 KiB | NPU 本地 SRAM |

固件由 ponwrt 自带的 linux-firmware 包提供（`airoha-en7581-npu-firmware` /
`airoha-an7583-npu-firmware`），在 `configs/<机型>.config` 里写
`CONFIG_PACKAGE_airoha-en7581-npu-firmware=y` 即会装进 rootfs。

工作流**不介入**固件的生成与选择：不再有现编、变体推断、DEFAULT_PACKAGES 摘除
等环节。要换固件就改 config 里那一行，改完照常 `make defconfig` 生效。

### 刷完怎么验

```sh
dmesg | grep -i npu           # probe 时打 NPU fw version
ls -l /lib/firmware/airoha/   # 两个 bin 在位
```

- 缺文件或名字不匹配：`request_firmware_direct()` 返回 `-ENOENT`，驱动映射成
  `-EPROBE_DEFER`，NPU 一直不绑定（`deferred probe pending` 里能看到具体文件名）。
- 大小超限：直接 `-E2BIG`。
- LuCI「Airoha SoC 状态页」（`luci-app-airoha-npu`）可看 NPU 卸载 / PPE 流表是否正常。

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

