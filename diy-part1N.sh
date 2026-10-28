#!/usr/bin/env bash
# ================================================================
# diy-part1.sh —— 拉取可选插件到 package/custom 并校验索引
#
# 运行目录：ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
# 用法：把需要的插件开关改成 true，再到 configs/<机型>.config 里
#      把对应 "# CONFIG_PACKAGE_xxx is not set" 改成 "=y"
# ================================================================

# FIX #1: 严格模式 + pipefail，任何命令失败都立即退出
set -Eeuo pipefail
IFS=$'\n\t'

# FIX #6: 统一日志与 Actions 分组
readonly SCRIPT_START=$(date +%s)
readonly PKG_DIR="$(pwd)/package/custom"          # FIX: 用绝对路径
readonly PKGINFO="tmp/.packageinfo"

# ---------------------------------------------------------
# 插件开关（显式声明每一个，避免未定义变量）
# ---------------------------------------------------------
readonly ADD_AIROHA_NPU=true    # luci-app-airoha-npu（Airoha SoC 状态页）
readonly ADD_PASSWALL=false     # luci-app-passwall（含依赖源）
readonly ADD_OPENCLASH=false    # luci-app-openclash ⚠ 依赖 Ruby/Rust，编译极慢
readonly ADD_MOSDNS=false       # luci-app-mosdns + v2ray-geodata
readonly ADD_LUCKY=false        # luci-app-lucky（DDNS + socat）
readonly ADD_TAILSCALE=false    # luci-app-tailscale
readonly ADD_OPENLIST=false     # luci-app-openlist2（alist/openlist 挂载）
readonly ADD_SMARTDNS=false     # luci-app-smartdns
readonly ADD_LUCI_APP=false     # FIX #3: 显式声明，natmode / pon-status 开关

# ---------------------------------------------------------
# FIX #4: 插件清单化——把所有"开关 + 仓库 + 目录 + 分支"集中到这里
#         新增插件只需在数组里加一行，不再到处复制粘贴 if
# ---------------------------------------------------------
readonly PKG_LIST=(
  # name                          | enabled | url                                                            | branch
  "luci-app-airoha-npu|${ADD_AIROHA_NPU}|https://github.com/luanmuc/luci-app-airoha-npu|main"
  "openwrt-passwall-packages|${ADD_PASSWALL}|https://github.com/xiaorouji/openwrt-passwall-packages|main"
  "openwrt-passwall|${ADD_PASSWALL}|https://github.com/xiaorouji/openwrt-passwall|main"
  "luci-app-mosdns|${ADD_MOSDNS}|https://github.com/sbwml/luci-app-mosdns|v5"
  "v2ray-geodata|${ADD_MOSDNS}|https://github.com/sbwml/v2ray-geodata|master"
  "luci-app-lucky|${ADD_LUCKY}|https://github.com/sirpdboy/luci-app-lucky|main"
  "luci-app-tailscale|${ADD_TAILSCALE}|https://github.com/asvow/luci-app-tailscale|main"
  "luci-app-openlist2|${ADD_OPENLIST}|https://github.com/sbwml/luci-app-openlist2|main"
  "luci-app-smartdns|${ADD_SMARTDNS}|https://github.com/pymumu/luci-app-smartdns|master"
  "smartdns|${ADD_SMARTDNS}|https://github.com/pymumu/smartdns|master"
  "luci-app-natmode|${ADD_LUCI_APP}|https://github.com/qwe3017/luci-app|main"
  "luci-app-pon-status|${ADD_LUCI_APP}|https://github.com/qwe3017/luci-app|main"
)

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "::error::$*" >&2; exit 1; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# FIX #5: 带指数退避的重试
retry() {
  local attempts=$1 max=$2; shift 2
  while (( attempts <= max )); do
    if "$@"; then return 0; fi
    local rc=$?
    log "  ↻ 第 ${attempts}/${max} 次失败（rc=${rc}），${attempts}0s 后重试…"
    sleep $(( attempts * 10 ))
    attempts=$(( attempts + 1 ))
  done
  return 1
}

# FIX #2: git clone 正确处理退出码，并把日志写文件，失败时全量输出
clone() {
  # clone <url> <dest> [branch] [filter]
  local url="$1" dir="$2" br="${3:-}" filter="${4:---depth=1}"

  # 目录已存在且包含 .git 才算"已克隆"，半成品目录要清掉重试
  if [ -d "$dir/.git" ]; then
    log "  ↷ 已存在，跳过: $dir"
    return 0
  fi
  rm -rf "$dir"   # 清理可能的半成品

  local log_file
  log_file="$(mktemp /tmp/clone-XXXXXX.log)"
  local args=(git clone --progress $filter)
  [ -n "$br" ] && args+=(-b "$br")
  args+=("$url" "$dir")

  log "  ⤓ $(basename "$url") -> $dir"
  if ! retry 1 3 "${args[@]}" >"$log_file" 2>&1; then
    echo "--- git clone 失败，完整日志 ---" >&2
    cat "$log_file" >&2
    echo "-----------------------------------" >&2
    rm -f "$log_file"
    return 1
  fi
  rm -f "$log_file"

  # 校验 Makefile（插件仓库必须能被 buildroot 索引）
  if [ ! -f "$dir/Makefile" ] && [ -z "${MULTI_PKG_REPO:-}" ]; then
    log "  ⚠ $dir 无根 Makefile，视为源仓库/子包容器"
  fi
  local commit
  commit=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  log "  ✅ $(basename "$dir") @ ${commit}"
}

# ================================================================
# 主流程
# ================================================================
group "拉取可选插件 (diy-part1.sh)"
mkdir -p "$PKG_DIR"
endgroup

group "克隆插件仓库（共 ${#PKG_LIST[@]} 项清单）"
FAILED_PKGS=()
for entry in "${PKG_LIST[@]}"; do
  IFS='|' read -r name enabled url branch <<<"$entry"
  [ "$enabled" = "true" ] || { log "  ⊘ $name 未启用"; continue; }
  if ! clone "$url" "$PKG_DIR/$name" "$branch"; then
    FAILED_PKGS+=("$name")
    echo "::error::克隆失败: $name ($url)"
  fi
done
endgroup

# 特殊处理：passwall 仓库里嵌套了 luci-app-passwall2，需要剔除
if [ "$ADD_PASSWALL" = "true" ] && [ -d "$PKG_DIR/openwrt-passwall/luci-app-passwall2" ]; then
  rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2"
  log "  ✂ 已剔除 luci-app-passwall2"
fi

(( ${#FAILED_PKGS[@]} == 0 )) || die "以下插件克隆失败: ${FAILED_PKGS[*]}"

group "清理重复嵌套目录"
# rchen14b/luci-app-airoha-npu 之类的仓库会在根目录 + 同名子目录里各放一份，
# 会把 custom feed 的扫描打断。用 find 一次性处理所有层级。
while IFS= read -r nested; do
  local_dir="${nested%/*}"           # <pkg>/<pkg>/Makefile -> <pkg>
  pkg_name="$(basename "$local_dir")"
  rm -rf "$nested"
  log "  ✂ 已移除重复嵌套目录: $local_dir/$(basename "$nested")"
done < <(find "$PKG_DIR" -mindepth 2 -maxdepth 2 -type d -name Makefile \
          -exec sh -c 'd=$(dirname "{}"); n=$(basename "$d"); \
                        [ -f "$d/$n/Makefile" ] && echo "$d/$n/Makefile"' \;)
endgroup

group "重建包索引"
# 一定要删 stamp：prepare-tmpinfo 有 scan_unchanged 优化，stamp 不删索引不会重建
rm -f tmp/.packageinfo tmp/.targetinfo
rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
rm -f tmp/.config-package.in tmp/.config-target.in

make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true
[ -s "$PKGINFO" ] || die "$PKGINFO 为空，prepare-tmpinfo 失败"
log "  ✅ tmp/.packageinfo 共 $(grep -c '^Package: ' "$PKGINFO") 个包"
endgroup

group "包索引校验"
INDEX_MISS=()
for d in "$PKG_DIR"/*; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  [ -f "$d/Makefile" ] || { log "  ⊘ $n（无根 Makefile，跳过）"; continue; }
  if grep -qx "Package: $n" "$PKGINFO"; then
    log "  ✅ $n"
  else
    log "  ❌ $n 未进索引"
    INDEX_MISS+=("$n")
    # 真实错误在 logs/package/<dir>/dump.txt
    for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
      [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
    done
  fi
done
endgroup

group "必装插件硬校验"
# FIX #7: 把 config 中已开 =y 的插件纳入硬校验
CRITICAL_PKGS=(luci-app-airoha-npu)
[ "$ADD_LUCI_APP" = "true" ] && CRITICAL_PKGS+=(luci-app-natmode luci-app-pon-status)
# 如你的 configs/<机型>.config 还硬编了别的 =y 包，加在这里
# CRITICAL_PKGS+=(luci-app-passwall luci-app-mosdns)

HARD_MISS=()
for r in "${CRITICAL_PKGS[@]}"; do
  grep -qx "Package: $r" "$PKGINFO" || HARD_MISS+=("$r")
done

[ -f feeds/luci/luci.mk ] || die "feeds/luci/luci.mk 缺失，LuCI app 无法解析"

if (( ${#HARD_MISS[@]} > 0 )); then
  for m in "${HARD_MISS[@]}"; do
    echo "::error::必装插件 $m 未进索引，defconfig 会静默剔除 =y"
  done
  exit 1
fi
log "  ✅ 必装插件全部就绪: ${CRITICAL_PKGS[*]}"
endgroup

# ================================================================
# 覆盖 feeds/luci 中自带的 dae / honk（保持你原有逻辑）
# ================================================================
group "覆盖 feeds/luci 中的 dae / honk"
clone https://github.com/QiuSimons/luci-app-dae    feeds/luci/applications/luci-app-dae
clone https://github.com/kenzok8/openwrt-honk.git  feeds/luci/applications/luci-app-honk  "" --depth=1
endgroup

# ================================================================
# FIX #6: 输出 GitHub Step Summary，便于在 Actions 页面直接看结果
# ================================================================
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## diy-part1.sh 执行报告"
    echo ""
    echo "| 项目 | 值 |"
    echo "|---|---|"
    echo "| 启用插件 | $(grep -c 'true' <<<"${PKG_LIST[*]}" || true) |"
    echo "| 索引缺失 | ${INDEX_MISS[*]:-无} |"
    echo "| 必装校验 | ✅ 通过 |"
    echo "| 耗时 | $(( $(date +%s) - SCRIPT_START ))s |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "🎉 diy-part1.sh 执行完毕"
