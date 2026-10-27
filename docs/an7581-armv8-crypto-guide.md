# AN7581（Nokia XG-040G-MD / 贝尔 XG-140G-MD）硬件 AES 真相与激活指南

> 适用内核：Linux 6.18（`KERNEL_PATCHVER:=6.18`）｜目标：`airoha/an7581`（aarch64_cortex-a53）
> 本文件说明：① AN7581 到底有没有“硬件 AES”，它在哪里；② 为什么 `openssl speed -evp aes-128-gcm` 只有 ~29 MB/s；③ 本次已做的修改；④ 如何验证与手工配置。

---

## 1. 结论（先说重点）

**1) CPU 核（Cortex-A53）没有 ARMv8 Crypto Extension（无 AES/SHA1/SHA2/PMULL 指令）。**

这一点已被实测数据证实，而不是猜测：

| 证据 | 数值/现象 | 含义 |
|------|-----------|------|
| OpenSSL 编译产物 | `libcrypto.a` 内含 43 个 arm64 asm 符号（`aes_v8_*`、`gcm_ghash_v8`、`sha256_armv8` 等），且 `CONFIG_OPENSSL_WITH_ASM=y` | OpenSSL **确实编译了** ARMv8 汇编（没有被 no-asm 禁用） |
| 设备上 `openssl speed` 输出 | `CPUINFO: OPENSSL_armcap=0x1` | 运行时 HWCAP 探测**只发现 NEON**（bit0），AES(bit2)/SHA1/SHA2/PMULL 位全为 0 |
| `openssl speed -evp aes-128-gcm` | 16 KB 块仅 **~29 MB/s** | 这是纯 C 软件 AES-GCM 在 A53 上的典型水平；有 CE 时应为几百 MB/s~1 GB/s+ |

> 常见误解：“Cortex-A53 自带 AES 指令”。**不对** —— ARMv8 Crypto Extension 在 A53 上是**可选**特性，由 SoC 厂商决定是否实现。Airoha 在这颗 AN7581 上没有实现它（`ID_AA64ISAR0_EL1` 的 AES/SHA 位为 0，内核据此不设置对应 HWCAP，OpenSSL 因此探测不到）。

设备上最终确认命令（一锤定音）：

```shell
cat /proc/cpuinfo | grep Features
# 如果这一行里没有 aes sha1 sha2 pmull，就说明 CPU 核确实没有硬件 AES 指令
# （有的话形如: fp asimd evtstrm aes pmull sha1 sha2 crc32 ...）
```

**2) 硬件 AES 真实存在，但它是 SoC 里的一块独立安全引擎：Inside Secure EIP-93。**

- DTS 节点（`target/linux/airoha/dts/an7581.dtsi`，已存在且默认启用，DTB 中已确认）：

```
crypto@1fb70000 {
    compatible = "inside-secure,safexcel-eip93ies";
    reg = <0x0 0x1fb70000 0x0 0x1000>;
    interrupts = <GIC_SPI 44 IRQ_TYPE_LEVEL_HIGH>;
};
```

- 内核 6.18 自带驱动：`drivers/crypto/inside-secure/eip93/`，Kconfig 符号 `CONFIG_CRYPTO_DEV_EIP93`（`depends on SOC_MT7621 || ARCH_AIROHA || COMPILE_TEST`，本目标满足）。
- **修改前该驱动没有编译进内核**（`config-6.18` 片段里没有任何 `CONFIG_CRYPTO_DEV_EIP93`），所以这块硬件 AES 一直是“有硬件、没驱动”的状态。这就是“硬件 AES 没有生效”的真正原因。

---

## 2. EIP-93 能加速什么、不能加速什么（重要）

驱动注册的算法（`cra_priority = 1500`，远高于软件实现，注册后自动优先）：

| 类型 | 算法 | 典型用途 |
|------|------|----------|
| skcipher | `ecb(aes)` / `cbc(aes)` / `ctr(aes)` / `rfc3686(ctr(aes))` | IPsec ESP-CBC、TLS-CBC、各类 CTR 场景 |
| aead | `authenc(hmac(md5/sha1/sha224/sha256/sha384/sha512), cbc(aes))` | IPsec ESP-AES-CBC-HMAC（strongswan 等） |
| skcipher | DES/3DES ECB/CBC | 兼容性用途 |

**不支持 GCM/CCM**（驱动注释：CCM 只在 EIP-93IW 变体上，且当前驱动未支持；GCM 需要 GHASH/PMULL，本引擎没有）。

因此：

- **`openssl speed -evp aes-128-gcm` 无法被硬件加速** —— 这是硬件能力限制，不是配置问题。GCM 在本设备上无论用户态（OpenSSL/mbedTLS）还是内核态都只能是软件实现。这个预期要接受。
- **内核态 gcm(aes) 的 CTR 部分会受益**：内核 `gcm(aes)` 由 `ctr(aes)` + GHASH 组成，EIP-93 的 `ctr(aes)`（优先级 1500）会被选上，CTR 部分走硬件，GHASH 部分仍为软件（CPU 无 PMULL）。
- **用户态 OpenSSL 的 CBC/CTR/ECB 可以通过 devcrypto 引擎吃到硬件加速**（见第 4 节）。

---

## 3. 本次已做的修改

### 3.1 内核配置片段 `target/linux/airoha/an7581/config-6.18`

**新增：**

```kconfig
CONFIG_CRYPTO_DEV_EIP93=y          # EIP-93 硬件加密引擎（真正的硬件 AES）
CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y # NEON 版 AES 模式实现（无需 CE，XTS 等模式软件加速）
```

**删除（本 CPU 无法加载，属于无效配置）：**

```kconfig
# 原 CONFIG_CRYPTO_AES_ARM64_CE=y       删除（需 AESE/AESD 指令，本 CPU 无）
# 原 CONFIG_CRYPTO_AES_ARM64_CE_BLK=y   删除（同上）
# 原 CONFIG_CRYPTO_AES_ARM64_CE_CCM=y   删除（同上）
# 原 CONFIG_CRYPTO_GHASH_ARM64_CE=y     删除（需 PMULL 指令，本 CPU 无）
```

> 说明：arm64 的 CE 驱动带 `module_cpu_feature_match(AES/PMULL)` 门控，本 CPU 上这些模块即使编译了也**不会加载**（不是崩溃，是静默不注册）。留着只会误导，故删除。`CONFIG_CRYPTO_AES_ARM64`（纯标量汇编 AES，不需要 CE）**保留**，它在本 CPU 上可以正常加载，比通用 C 略快。

### 3.2 OpenWrt 包配置 `.config`

```kconfig
CONFIG_PACKAGE_kmod-cryptodev=y          # /dev/crypto 用户态接口（cryptodev-linux）
CONFIG_PACKAGE_libopenssl-devcrypto=y    # OpenSSL devcrypto 引擎（engine_id: devcrypto）
```

### 3.3 设备树

无需修改：`crypto@1fb70000` 节点已存在、默认启用、compatible 与驱动匹配、reg/中断齐全（驱动 probe 只需 reg + IRQ）。

### 3.4 未做改动（说明）

- OpenSSL 本身 `CONFIG_OPENSSL_WITH_ASM=y` 一直是对的，不需要改。
- mbedTLS `MBEDTLS_AESCE_C` 同理：汇编已编译，但运行时探测不到 CE，自动回退 C 实现——不是配置问题。

---

## 4. 编译与刷机后验证

### 4.1 重新编译

```shell
./scripts/feeds update -a && ./scripts/feeds install -a   # 先恢复 feeds（当前 worktree 的 feeds/packages 不完整，缺 openssl 包源码）
make defconfig                                            # 让 .config 改动规范化
make -j$(nproc)
```

### 4.2 验证命令

```shell
# 1) CPU 核特性（应【没有】aes/sha1/sha2/pmull —— 这是正常现象，不是故障）
cat /proc/cpuinfo | grep Features

# 2) OpenSSL 运行时能力（应为 0x1，仅 NEON）
openssl version -a | grep -i cap

# 3) 内核态：EIP-93 驱动与算法已注册（driver 列出现 eip93）
grep -E '^(name|driver|module)' /proc/crypto | grep -B1 -A2 eip93

# 4) 内核态：gcm(aes) 的 ctr 组件已走 EIP-93（driver 出现 ctr(aes-eip93)）
grep -A3 '^name         : ctr(aes)$' /proc/crypto

# 5) 用户态 OpenSSL 走 devcrypto 引擎（CBC/CTR 应有明显硬件加速）
openssl speed -engine devcrypto -evp aes-128-cbc -bytes 16384
openssl speed -engine devcrypto -evp aes-128-ctr -bytes 16384

# 6) GCM（预期仍为软件速度，硬件能力限制，见第 2 节）
openssl speed -evp aes-128-gcm -bytes 16384
```

预期 `/proc/crypto` 中出现：

```
ecb(aes)  -> ecb(aes-eip93)
cbc(aes)  -> cbc(aes-eip93)
ctr(aes)  -> ctr(aes-eip93)
authenc(hmac(sha256),cbc(aes)) -> authenc(hmac(sha256-eip93),cbc(aes-eip93))
```

### 4.3 收益场景

| 场景 | 是否加速 | 说明 |
|------|----------|------|
| 内核 IPsec（strongswan ESP-AES-CBC-HMAC） | ✅ 硬件 | authenc 直接走 EIP-93，无需任何用户态配置 |
| 内核 AF_ALG / cryptodev 用户（CBC/CTR/ECB） | ✅ 硬件 | 优先级 1500 自动胜出 |
| OpenSSL（经 devcrypto 引擎）CBC/CTR/ECB | ✅ 硬件 | `openssl speed -engine devcrypto -evp aes-128-cbc` |
| OpenSSL / 内核 AES-GCM | ❌ 软件 | EIP-93 无 GCM；CPU 无 PMULL（GHASH 无硬件） |
| OpenSSL / 内核 SHA | ❌ 软件 | CPU 无 SHA1/SHA2 指令 |

---

## 5. 手工配置方法（备用）

### 5.1 EIP-93 引擎（内核符号，menuconfig 不可见）

方式 A（推荐，持久）：编辑 `target/linux/airoha/an7581/config-6.18`，保持字母序加入：

```kconfig
CONFIG_CRYPTO_DEV_EIP93=y
CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y
```

方式 B：`make kernel_menuconfig` → **Cryptographic API → Hardware crypto devices** → `Support for EIP93 crypto HW accelerators`（`CONFIG_CRYPTO_DEV_EIP93`），保存后自动写回片段。

### 5.2 devcrypto 用户态接口（menuconfig 可见）

```shell
make menuconfig
# Kernel modules → Cryptographic API modules → kmod-cryptodev
# Libraries → SSL → libopenssl-devcrypto
```

### 5.3 不要开启的项目

| 选项 | 原因 |
|------|------|
| `CONFIG_CRYPTO_AES_ARM64_CE*` / `CONFIG_CRYPTO_GHASH_ARM64_CE` | 需 AES/PMULL 指令，本 CPU 无，模块不会加载 |
| `CONFIG_CRYPTO_SHA3_ARM64` / `SM3_ARM64_CE` / `SM4_ARM64_CE*` | 需 ARMv8.2+ 指令，本 CPU 无 |
| `CONFIG_CRYPTO_AES_ARM64_BS` | bit-sliced NEON，本场景收益有限，EIP-93 已覆盖主要模式 |

---

## 6. 结论速览

- CPU 核 **没有** 硬件 AES（无 ARMv8 CE）—— 用 `/proc/cpuinfo` 的 `Features` 行确认。
- 硬件 AES 在 **EIP-93 独立引擎**（`crypto@1fb70000`）里，驱动此前未编译 —— 本次通过 `CONFIG_CRYPTO_DEV_EIP93=y` 激活。
- 激活后：内核 IPsec/AF_ALG 及 OpenSSL devcrypto 引擎的 **AES-CBC/CTR/ECB** 获得硬件加速；**AES-GCM 仍是软件**（硬件能力限制），`openssl speed -evp aes-128-gcm` 维持 ~29 MB/s 属正常。
