# AN7583（Nokia XG-040G-MF）硬件 AES 支持与开启情况核查

> 核查对象：`airoha/an7583`，机型 `nokia,xg-040g-mf-ubi`（本机 `.config` 当前唯一选中的 profile）
> 核查方式：源码/配置静态核对 + 活体机器实测（`op` = `192.168.32.254`，PonWrt r41551+12-c3b518baec，内核 6.18.52）
> 参照：`~/work/openwrt_XG-140G-MD/docs/an7581-armv8-crypto-guide.md`（AN7581 上那次硬件 AES 修复）

---

## 0. 结论速览

| 层面 | AN7581（140G-MD） | **AN7583（XG-040G-MF）** | 当前 PonWrt 是否已开 |
|---|---|---|---|
| CPU 核 ARMv8 Crypto Extensions | **没有**（`OPENSSL_armcap=0x1`，仅 NEON） | **有**（`0x3d`：AES+PMULL+SHA1+SHA256）`[实测]` | 用户态**已自动生效** |
| 独立安全引擎 EIP-93（`crypto@1fb70000`） | 有硬件、原先无驱动 → 用 `CONFIG_CRYPTO_DEV_EIP93` 修好 | DTS 节点同样存在 `[实测]` | **没开**（无驱动、无绑定） |
| 内核 skcipher `ecb/cbc/ctr(aes)` | 只能软件（CE 不可用） | 可用 CE 硬件，但**内核完全没编** `[实测]` | **没开** |
| 内核 `gcm(aes)` / GHASH | 软件（无 PMULL） | 可用 CE（PMULL），但 **`CONFIG_CRYPTO_GHASH_ARM64_CE` 没编** | **没开** |
| 内核 SHA-1/SHA-256 | 软件 | **已经是硬件**（`libsha1/sha256` 静态键自动选 CE） | 已自动生效 |
| AF_ALG / devcrypto | 140G-MD 装了 `kmod-cryptodev`+`libopenssl-devcrypto` | `CONFIG_CRYPTO_USER_API_*=n`，**内核根本没给用户态接口** | 没开（也不需要） |

一句话：**AN7583 的硬件 AES 比 AN7581 好得多——CPU 核自带 Crypto Extensions，用户态（OpenSSL / sing-box / xray / shadowsocks-rust）已经在跑硬件 AES；但内核态 AES/GHASH 目前是纯软件，因为 `an7583/config-6.18` 里一个 CE 选项都没开，EIP-93 驱动也没编。**

---

## 1. 硬件支持：AN7583 有两条硬件 AES 通路

### 1.1 CPU 核有 ARMv8 Crypto Extensions（与 AN7581 的关键差异）`[实测]`

活体机器（就是本仓库当前编译、刷进去的那台 XG-040G-MF）：

```
# cat /proc/cpuinfo | head -11
processor   : 0
model name  : ARMv8 Processor rev 4 (v8l)
Features    : fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid     ← 有 aes / pmull / sha1 / sha2
CPU implementer : 0x41          (ARM)
CPU part        : 0xd03         (Cortex-A53)
CPU revision    : 4
```

对比 140G-MD 文档里 AN7581 的记录（`OPENSSL_armcap=0x1`，即只有 NEON，`aes-128-gcm` 仅 ~29 MB/s）：
**同为 Cortex-A53，Airoha 只在 AN7583 上实现了 Crypto Extension**，所以 AN7581 必须靠 EIP-93，而 AN7583 直接用 CPU 指令即可（而且 CE 支持 GCM，EIP-93 不支持）。

### 1.2 EIP-93 安全引擎节点也在（但当前没驱动）

`target/linux/airoha/dts/an7583.dtsi`：

```dts
crypto@1fb70000 {
	compatible = "inside-secure,safexcel-eip93ies";
	reg = <0x0 0x1fb70000 0x0 0x1000>;
	interrupts = <GIC_SPI 44 IRQ_TYPE_LEVEL_HIGH>;
};
```

与 AN7581 完全同址同中断；`drivers/crypto/inside-secure/eip93/eip93-main.c` 的 `of_device_id` 表里有 `inside-secure,safexcel-eip93ies`，即只要 Kconfig 打开就能绑上。

活体核对：节点在（`/sys/firmware/devicetree/base/soc/crypto@1fb70000/` 有 `compatible/reg/interrupts`），
但 `/sys/bus/platform/drivers/` 里没有任何 crypto/eip93 驱动，`/proc/crypto` 里也没有 eip93 条目 ⇒ **硬件在、驱动没编**。

> EIP-93 相对 CE 的短板：只有 ECB/CBC/CTR/DES/authenc，**没有 GCM/CCM**。AN7583 上 CE 同时覆盖 AES 全模式和 GHASH，所以 EIP-93 在本机型上属于「可选补充」，不是必需（见第 4 节）。

---

## 2. 用户态：硬件 AES 已经在跑，不需要任何配置 `[实测]`

关键点：`CONFIG_OPENSSL_WITH_ASM=y`（`.config:5345`）⇒ libcrypto 里编进了 ARMv8 汇编，
运行时按 `AT_HWCAP` 自动选择 `aes_v8_*` / `gcm_ghash_v8`（PMULL）。

用仓库自带工具链交叉编译一个小探针（源码 `docs/an7583-aes-check.c`，二进制临时放在 `tmp/aes-check/`），
静态链 `libcrypto.a` 的版本打印 OPENSSL 内部能力位，动态链**设备上装的** `libcrypto.so.3` 的版本测真实吞吐：

```
$ /tmp/aes-check          # 静态链 libcrypto.a（可打印 OPENSSL_armcap_P）
OpenSSL      : OpenSSL 3.5.8 25 Aug 2026
AT_HWCAP     : 0x8ff  asimd=1 aes=1 pmull=1 sha1=1 sha2=1
OPENSSL_armcap_P : 0x3d  neon=1 aes=1 sha1=1 sha256=1 pmull=1
aes-128-gcm  :    569.7 MB/s
aes-256-gcm  :    506.4 MB/s
aes-128-cbc  :    889.4 MB/s
aes-128-ctr  :    866.2 MB/s
chacha20-poly1305 :    199.4 MB/s

$ /tmp/aes-check-dyn      # 动态链设备上的 /usr/lib/libcrypto.so.3
aes-128-gcm  :    568.5 MB/s     ← 与静态版一致 ⇒ 固件里那份库确实走 CE
```

判读：
* `OPENSSL_armcap_P = 0x3d` = NEON|AES|SHA1|SHA256|PMULL（AN7581 是 `0x1`）；
* GCM 570 MB/s 远高于纯 C 的水平（AN7581 实测 29 MB/s），且比同机的 ChaCha20-Poly1305（199 MB/s，纯 NEON）快 ⇒ 确实是 AES 指令 + PMULL 在做；
* 本机跑的是 **PassWall（sing-box / xray / shadowsocks-rust）+ WireGuard**（`.config:6203-6211,3938`），
  这些用户态实现的 Go/Rust 加密库同样是运行时探测 HWCAP，**自动吃到 CE，无需改动**。

---

## 3. 内核态：AES 侧一个都没开（AN7581 那次修复也没有移植过来）

### 3.1 源码/配置现状

```
$ grep -E "^CONFIG_(CRYPTO|ARM64|KERNEL_MODE_NEON)" target/linux/airoha/an7583/config-6.18
CONFIG_CRYPTO_CRC32C=y
CONFIG_CRYPTO_DEFLATE=y
CONFIG_CRYPTO_ECB=y
CONFIG_CRYPTO_HASH_INFO=y
CONFIG_CRYPTO_LIB_GF128MUL=y
CONFIG_CRYPTO_LIB_SHA1=y
CONFIG_CRYPTO_LIB_SHA1_ARCH=y
CONFIG_CRYPTO_LIB_SHA256_ARCH=y
CONFIG_CRYPTO_LIB_UTILS=y
CONFIG_CRYPTO_LZO=y
CONFIG_CRYPTO_ZSTD=y

$ diff <(grep -E "^CONFIG_(CRYPTO|ARM64|KERNEL_MODE_NEON)" target/linux/airoha/an7581/config-6.18) \
       <(grep -E "^CONFIG_(CRYPTO|ARM64|KERNEL_MODE_NEON)" target/linux/airoha/an7583/config-6.18)
（无差异）

$ grep -rn "ARM64_CE\|AES_ARM64\|GHASH" target/linux/airoha/
（空）
```

已生成的内核配置（`build_dir/.../linux-airoha_an7583/linux-6.18.52/.config`）：

```
# CONFIG_CRYPTO_AES_ARM64 is not set
# CONFIG_CRYPTO_AES_ARM64_CE is not set
# CONFIG_CRYPTO_AES_ARM64_CE_BLK is not set
# CONFIG_CRYPTO_AES_ARM64_NEON_BLK is not set
# CONFIG_CRYPTO_AES_ARM64_BS is not set
# CONFIG_CRYPTO_GHASH_ARM64_CE is not set
# CONFIG_CRYPTO_CBC is not set          ← 连软件 CBC 都没有
# CONFIG_CRYPTO_HW is not set           ← EIP-93 前提
# CONFIG_CRYPTO_USER_API_SKCIPHER is not set   ← AF_ALG 关闭
```

包层面（`.config` / `configs/an7583.config` 都是默认关闭）：

```
# CONFIG_PACKAGE_kmod-crypto-hw-eip93 is not set
# CONFIG_PACKAGE_kmod-cryptodev is not set
# CONFIG_PACKAGE_libopenssl-devcrypto is not set
```

> **一个坑（历史证据）**：an7583 的 `config-6.18` **曾经**有 `CONFIG_CRYPTO_DEV_EIP93=y`
> （`e89e9c412f`：从 6.12 抄 6.18 文件时带过来的），随后被上游 `ada7ded2f4 "airoha: an7583: refresh
> kernel config"`（`make kernel_oldconfig`）**静默删掉**。原因在 `drivers/crypto/Kconfig`：

```
12:if CRYPTO_HW
…
875:source "drivers/crypto/inside-secure/eip93/Kconfig"
878:endif # CRYPTO_HW
```

> `CRYPTO_DEV_EIP93` 在 `if CRYPTO_HW` 里面：`CRYPTO_HW=n` 时这个符号**不可见**，写进片段也会在下次
> `make defconfig`/`kernel_oldconfig` 时被丢掉。所以 140G-MD 那边走的是 kmod 包
> （`kmod-crypto-hw-eip93` 的 `KCONFIG` 里第一行就是 `CONFIG_CRYPTO_HW=y`，见
> `package/kernel/linux/modules/crypto.mk`），而不是光在片段里写 EIP93。
> 反观 `arch/arm64/crypto/Kconfig`（AES/GHASH 的 CE 选项）由 `crypto/Kconfig` 在 `if ARM64` 下直接 source，
> **不受 `CRYPTO_HW` 门控**，所以 CE 系列可以直接写进 `an7583/config-6.18`。

### 3.2 活体核对 `[实测]`

```
# /proc/crypto 里一共只有 13 个算法，全是 software/generic：
aes            <- aes-generic
ecb(aes)       <- ecb(aes-generic)
ghash          <- ghash-generic
sha1           <- sha1-lib
hmac(sha1)     <- hmac-sha1-lib
…（无 cbc(aes) / ctr(aes) / gcm(aes)，更没有任何 CE/EIP93 driver）

# ls /lib/modules/6.18.52/kernel/arch/arm64/crypto/     → 不存在
# ls /lib/modules/6.18.52/kernel/crypto/                → 不存在
# ls -l /dev/crypto                                     → No such file（未装 cryptodev）
# ls /sys/bus/platform/drivers/ | grep -iE "eip|crypto" → 空
```

### 3.3 内核里唯一用到 AES 的地方：PON PLOAM 换密钥（每帧一 block，可忽略）

`feeds/pon_drivers/airoha-xpon/src/airoha-xpon-crypto.c` 用内核 crypto API 做单块 AES：

```c
xpon->crypto.aes = crypto_alloc_sync_skcipher("ecb(aes)", 0, 0);   // 当前解析到 ecb(aes-generic)
…
ret = airoha_xpon_aes_encrypt_block(xpon, kek, data_key, encrypted_data_key);  // ploam.c:769
```

用途只有 PLOAM 密钥交换（KEK 加密新 data key，一次一个 block）；**数据面 XGEM 的 AES 由 PON MAC 硬件完成**
（密钥通过 `AIROHA_XGPON_AES_UC_IDX*_KEY*` 寄存器下发），不占 CPU。所以「内核 AES 是软件」在这台 ONU 上
对转发性能几乎没有影响——想拉开差距的是 IPsec / dm-crypt / 走内核的 GCM，而这台机器目前都没装。

### 3.4 已经吃到硬件的那半：内核 SHA-1/SHA-256

内核 6.18 把 arm64 SHA 的 CE 分支并进了 `lib/crypto`（旧符号 `CONFIG_CRYPTO_SHA1_ARM64_CE` /
`CRYPTO_SHA2_ARM64_CE` 在 6.18 里已经不存在，OpenWrt 的 `generic/config-6.18` 里那两行是陈旧条目）。
`lib/crypto/arm64/sha256.h` 用 static key 运行时探测：

```c
static void sha256_mod_init_arch(void) {
	if (cpu_have_named_feature(ASIMD)) { static_branch_enable(&have_neon);
		if (cpu_have_named_feature(SHA2)) static_branch_enable(&have_ce); } }
```

AN7583 的 `CONFIG_CRYPTO_LIB_SHA256_ARCH=y` + `CONFIG_KERNEL_MODE_NEON=y` + CPU 有 SHA2 ⇒
内核 SHA 已经是硬件（`/proc/crypto` 里名称仍显示 `sha1-lib`，那是 lib 实现内部按 static key 分流，不代表软件）。

---

## 4. 如果要开（建议方案）

**只改 `target/linux/airoha/an7583/config-6.18`（按字母序插），AN7581 不要动**（那颗没 CE，编了也不注册）：

```kconfig
CONFIG_CRYPTO_AES_ARM64=y            # 标量汇编 AES（CE/NEON 的公共依赖）
CONFIG_CRYPTO_AES_ARM64_BS=y         # bit-sliced NEON，A53 上比纯 C 快
CONFIG_CRYPTO_AES_ARM64_CE=y         # ★ aes-ce：ECB/CBC/CTR 走 AES 指令
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y     # ★ 块模式（cbc/ecb/ctr/xts）
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y     # CCM
CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y   # AES-NEON 模式层
CONFIG_CRYPTO_CBC=y                  # ← 现在连软件 CBC 都没有，IPsec 必需
CONFIG_CRYPTO_GHASH_ARM64_CE=y       # ★ GHASH（PMULL）→ gcm(aes) 转硬件
```

（依赖都已满足：`KERNEL_MODE_NEON=y`、`ARCH_AIROHA`；`CRYPTO_*_ARM64_CE` 系列都 `depends on KERNEL_MODE_NEON`。
`CRYPTO_SHA3_ARM64`/`SM3_ARM64_CE`/`SM4_ARM64_*`/`CRYPTO_SHA512_ARM64_CE` 需要 ARMv8.2 指令，A53 **不能开**。）

可选补充（想走 140G-MD 那条 EIP-93 路线）：

```kconfig
CONFIG_CRYPTO_HW=y                  # ← 必须先有它，否则下一行会被 defconfig 丢掉（见 3.1 的坑）
CONFIG_CRYPTO_DEV_EIP93=y            # 或把 CONFIG_PACKAGE_kmod-crypto-hw-eip93 设成 y（包内 KCONFIG 里 =m）
```
EIP-93 能给的是 `authenc(hmac(…),cbc(aes))`（IPsec ESP-AES-CBC-HMAC）与 DES/3DES；AN7583 上 CE 已经覆盖
AES 各模式 + GCM，**优先级/能力都更好**，所以对这台机器是「锦上添花」。

> **2026-10-08 更新**：按使用要求「全部开启」，上面这两条最终**也一起开了**（EIP-93 的硬件存在性已用只读寄存器探针实测确认，见第 7 节）。
> 结论不变：AN7583 上真正跑得快的是 **CE**；EIP-93 与 devcrypto 属于「开着不亏、但别指望它提速」的补充项。

改完的验证：

```sh
# 1) CE 驱动注册上了（应出现 aes-ce / ghash-ce 等 driver）
grep -E "^(name|driver)" /proc/crypto | grep -iE "ce$|-ce|arm64" 
grep -A3 "^name         : ecb(aes)$"  /proc/crypto     # 期望 driver: ecb(aes-ce)
grep -A3 "^name         : gcm(aes)$"  /proc/crypto     # 期望 driver: gcm_base(ctr-aes-ce,ghash-ce)
# 2) 用户态不变（本来就已硬件）：
/tmp/aes-check                                          # armcap=0x3d，aes-128-gcm ~570 MB/s
```

---

## 5. 复现方法与证据留痕

* 探针源码：`docs/an7583-aes-check.c`；编译/运行：

```sh
TC=staging_dir/toolchain-aarch64_cortex-a53_gcc-14.4.0_musl/bin/aarch64-openwrt-linux-gcc
S=staging_dir/target-aarch64_cortex-a53_musl/usr
$TC -O2 -static -I$S/include docs/an7583-aes-check.c -o /tmp/aes-check       $S/lib/libcrypto.a -lpthread -ldl
$TC -O2 -DNO_ARMCAP -I$S/include docs/an7583-aes-check.c -o /tmp/aes-check-dyn $S/lib/libcrypto.so -Wl,-rpath,/usr/lib
cat /tmp/aes-check | ssh op 'cat > /tmp/aes-check && chmod +x /tmp/aes-check'   # 该固件无 sftp-server，scp 不可用
ssh op '/tmp/aes-check; /tmp/aes-check-dyn'
```

* 交叉核对用的命令（都在第 1/3 节里给了原始输出）：`/proc/cpuinfo`、`/proc/crypto`、
  `ls /sys/bus/platform/drivers/`、`ls /lib/modules/$(uname -r)/kernel/{crypto,arch/arm64/crypto}`、
  `ls /dev/crypto`、`ls /sys/firmware/devicetree/base/soc/crypto@1fb70000/`。

## 6. 未核实/注意

* ~~EIP-93 在这颗 AN7583 上是否真能出数据，没有实测~~ → **已在 2026-10-08 用只读寄存器探针实测确认硬件存在**（第 7.2 节）。
  仍未做的是「出数据」级别的测试（跑一次真实加解密），因为旧固件内核缺 `authenc/des/md5/sha*` 符号，
  完整驱动模块插不进去；刷入本固件后可再验一次。
* 活体机器固件是 `r41551+12-c3b518baec`（比当前 worktree 早若干提交），但 `an7583/config-6.18` 里
  **从来没有任何 ARM64 CE 选项**（`git log -p --follow -- target/linux/airoha/an7583/config-6.18 | grep CRYPTO`
  里与硬件相关的只有那条被删掉的 `CONFIG_CRYPTO_DEV_EIP93=y`，见 3.1），
  所以「内核 AES 未开」对当前 worktree 同样成立。

---

## 7. 本次改动（2026-10-08，已编译进固件）

### 7.1 改了哪些配置

`target/linux/airoha/an7583/config-6.18`（**只动 an7583；an7581 一行没改**，那颗没 CE）：

```kconfig
+CONFIG_CRYPTO_AES_ARM64=y
+CONFIG_CRYPTO_AES_ARM64_BS=y
+CONFIG_CRYPTO_AES_ARM64_CE=y            # ★ AES 走 ARMv8 AES 指令
+CONFIG_CRYPTO_AES_ARM64_CE_BLK=y        # ★ ECB/CBC/CTR/XTS 块模式
+CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
+CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y
+CONFIG_CRYPTO_AUTHENC=y                 # authenc(hmac,cbc(aes)) → IPsec
+CONFIG_CRYPTO_CBC=y                     # 之前连软件 CBC 都没有
+CONFIG_CRYPTO_GHASH_ARM64_CE=y          # ★ PMULL → gcm(aes) 全硬件
+CONFIG_CRYPTO_HW=y                      # EIP-93 的前提（在 if CRYPTO_HW 里）
+CONFIG_CRYPTO_DEV_EIP93=m               # EIP-93 驱动（模块）
+CONFIG_CRYPTO_DEV_EIP93_AES_128_SW_MAX_LEN=512
+CONFIG_CRYPTO_DEV_EIP93_GENERIC_SW_MAX_LEN=256
+CONFIG_CRYPTO_USER_API_AEAD=y           # AF_ALG：内核算法给用户态用
+CONFIG_CRYPTO_USER_API_HASH=y
+CONFIG_CRYPTO_USER_API_SKCIPHER=y
```

> 两个 `EIP93_*_SW_MAX_LEN` 是 `hack-6.18/926-crypto-eip93-use-AES-fallback-for-small-requests.patch`
> 引入的新符号，**必须显式给值**，否则 `syncconfig` 会因为 (NEW) 无值而报错中断构建（第一次构建就踩了）。

`.config` / `configs/an7583.config`：

```
+CONFIG_PACKAGE_kmod-crypto-hw-eip93=y   # 自动带出 authenc/des/md5/sha1/sha256
+CONFIG_PACKAGE_kmod-cryptodev=y
+CONFIG_PACKAGE_libopenssl-devcrypto=y
```

`make defconfig` 后包数 239 → 245（只增不减）。

### 7.2 EIP-93 硬件存在性实测 `[实测]`

旧固件内核里 `ecb/cbc/gcm(aes)` 全软件、也没有 AF_ALG，但 **vermagic 与当前构建完全一致**
（`6.18.52 SMP mod_unload aarch64`，且 `CONFIG_MODVERSIONS=n`），所以可以编译一个**只读寄存器**的小模块
（`docs/an7583-eip93-probe-test.c`，只 `devm_platform_ioremap_resource` + `readl`，不注册算法、不依赖 authenc/des）
直接插进运行中的机器：

```
# insmod /tmp/eip93-probe-test.ko
[ 1377.731078] EIP93TEST: reg=[mem 0x1fb70000-0x1fb70fff] ctrl_stat=0x00000002 status=0x00040402
                option_1=0xf08fe007 revision=0x0341a25d eip_no=0x5d hw_rev=3.4 patch=1
[ 1377.745845] EIP93TEST: ALGO_AES=1 ALGO_DES=1 ALGO_HASH=1 (option_1 bits)
# ls /sys/bus/platform/drivers/eip93-probe-test/
1fb70000.crypto  bind  module  uevent  unbind
```

即：**AN7583 的 EIP-93 真的在**（EIP no. `0x5d` = EIP-93，hw rev 3.4，"ies" 变体，AES/DES/HASH 都置位），
DT 节点能正常绑定，寄存器可读，没有总线异常。（测试完已 `rmmod` 并删掉设备上的 `/tmp/*.ko`。）

顺带确认了旧内核为什么插不进完整驱动 —— 正是缺本次新增的那些符号：

```
# insmod /tmp/crypto-hw-eip93.ko
crypto_hw_eip93: Unknown symbol crypto_authenc_extractkeys (err -2)
crypto_hw_eip93: Unknown symbol des_expand_key (err -2)
crypto_hw_eip93: Unknown symbol md5_zero_message_hash (err -2)
crypto_hw_eip93: Unknown symbol sha224/256_zero_message_hash (err -2)
```

### 7.3 产物自检（离线核对的证据）

* 固件内核里确实带上了 CE / AF_ALG / authenc（把 FIT 里的内核解出来数特征串）：

```
$ python3 -c "…解 itb 里的 gzip 内核…"
kernel image bytes: 13973512
  cpu_feature_match_AES 2      # aes-ce-cipher / aes-ce-blk 的 CPU 特性门控
  ghash_ce              1
  algif_skcipher        1
  authenc               36
  cbc(aes               8
  rfc3686               8
  eip93                 0      # EIP-93 是模块，不在内核镜像里（符合预期）
```

* rootfs 里模块与依赖链齐全（`crypto-hw-eip93` 的 `depends=` 已由 kmod 自动写出）：

```
$ strings crypto-hw-eip93.ko | grep '^depends='
depends=sha1,sha256,libdes,md5
$ ls root-airoha/lib/modules/6.18.52/ | grep -E 'eip93|des|md5|sha'
crypto-hw-eip93.ko  cryptodev.ko  des_generic.ko  libdes.ko  libmd5.ko  md5.ko  sha1.ko  sha256.ko
$ cat root-airoha/etc/modules.d/09-crypto-hw-eip93 ; cat root-airoha/etc/modules.d/50-cryptodev
crypto-hw-eip93
cryptodev cryptodev_verbosity=-1
```

* 固件：`bin/targets/airoha/an7583/ponwrt-airoha-an7583-nokia_xg-040g-mf-ubi-squashfs-sysupgrade.itb`（2026-10-08 07:43）。
  manifest 里新增：`kmod-crypto-hw-eip93`、`kmod-crypto-authenc`、`kmod-crypto-des`、`kmod-crypto-md5`、
  `kmod-crypto-sha1`、`kmod-crypto-sha256`、`kmod-cryptodev`、`libopenssl-devcrypto`。

### 7.4 刷机后自检清单

```sh
# 1) 内核 CE 算法注册上了（最关键）
grep -A3 '^name         : ecb(aes)$'   /proc/crypto   # 期望 driver: ecb(aes-ce)
grep -A3 '^name         : cbc(aes)$'   /proc/crypto   # 期望 driver: cbc(aes-ce)
grep -A3 '^name         : ctr(aes)$'   /proc/crypto   # 期望 driver: ctr(aes-ce)
grep -A3 '^name         : gcm(aes)$'   /proc/crypto   # 期望 driver: gcm_base(ctr-aes-ce,ghash-ce)
grep -A3 '^name         : ecb(des)$'   /proc/crypto   # EIP-93：driver: ecb(des-eip93)
grep -c eip93 /proc/crypto                            # 期望 > 0（EIP-93 已加载）
lsmod | grep -E "eip93|cryptodev"

# 2) AF_ALG 用户态接口在
ls /sys/module/algif_skcipher  2>/dev/null || grep -c skcipher /proc/crypto

# 3) 用户态（本来就硬件，应保持不变）
#    刷机后 /tmp 会清空，需要按第 5 节的命令重新交叉编译并 cat | ssh 推上去
/tmp/aes-check                                        # armcap=0x3d，aes-128-gcm ~570 MB/s
openssl speed -engine devcrypto -evp aes-128-cbc -bytes 16384   # 可选：走内核 devcrypto

# 4) EIP-93 出数据（真正跑一次）
#    最省事：openssl 的 devcrypto 引擎会用到内核 skcipher/ecb(aes)；
#    或 dmesg | grep -i eip93 看驱动注册的算法列表
dmesg | grep -iE "eip93|safexcel"
```

如果 EIP-93 万一在启动时 probe 失败：本机 `panic_on_oops=1`，但 probe 失败是**返回错误**（不会 panic），
现象只是 `dmesg` 里一条报错 + `/proc/crypto` 没有 eip93；要临时禁用就删掉
`/etc/modules.d/09-crypto-hw-eip93`（或在 `target/linux/airoha/an7583/config-6.18` 里把
`CONFIG_CRYPTO_DEV_EIP93=m` 改成 `# CONFIG_CRYPTO_DEV_EIP93 is not set` 并去掉 `CONFIG_CRYPTO_HW=y`）。

