#!/usr/bin/env bash
# ================================================================
# diy-part1.sh —— 拉取可选插件到 package/custom 并校验索引
#
# 运行目录：ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
# 用法：把需要的插件开关改成 true，再到 configs/<机型>.config 里
#      把对应 "# CONFIG_PACKAGE_xxx is not set" 改成 "=y"
#
# 温度由 autocore 的 /sbin/tempinfo 提供（files/sbin/tempinfo），
# # ================================================================

# 严格模式 + pipefail，任何命令失败都立即退出
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_START=$(date +%s)
readonly PKG_DIR="$(pwd)/package/custom"          # 绝对路径，中途 cd 不失效
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

# ---------------------------------------------------------
# 插件清单——"开关 + 仓库 + 目录 + 分支"集中在这里
# 新增插件只需加一行，不再到处复制粘贴 if
# ---------------------------------------------------------
readonly PKG_LIST=(
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
)

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
die()     { echo "::error::$*" >&2; exit 1; }
group()   { echo "::group::$*"; }
endgroup(){ echo "::endgroup::"; }

# 带指数退避的重试
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

# git clone：正确处理退出码，日志写文件，失败时全量输出
clone() {
  # clone <url> <dest> [branch] [filter]
  local url="$1" dir="$2" br="${3:-}" filter="${4:---depth=1}"

  # 目录里含 .git 才算"已克隆"，半成品目录清掉重来
  if [ -d "$dir/.git" ]; then
    log "  ↷ 已存在，跳过: $dir"
    return 0
  fi
  rm -rf "$dir"

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

  if [ ! -f "$dir/Makefile" ]; then
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
ENABLED_COUNT=0
FAILED_PKGS=()
for entry in "${PKG_LIST[@]}"; do
  IFS='|' read -r name enabled url branch <<<"$entry"
  if [ "$enabled" != "true" ]; then
    log "  ⊘ $name 未启用"
    continue
  fi
  ENABLED_COUNT=$((ENABLED_COUNT + 1))
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
# 个别仓库（如 rchen14b/luci-app-airoha-npu）会在根目录 + 同名子目录里各放一份，
# 会把扫描打断。扫 <pkg>/Makefile，检查是否同时存在 <pkg>/<pkg>/Makefile。
while IFS= read -r mkfile; do
  pkg_dir="$(dirname "$mkfile")"
  pkg_name="$(basename "$pkg_dir")"
  nested="$pkg_dir/$pkg_name"
  if [ -d "$nested" ] && [ -f "$nested/Makefile" ]; then
    rm -rf "$nested"
    log "  ✂ 已移除重复嵌套目录: $pkg_name/$pkg_name"
  fi
done < <(find "$PKG_DIR" -mindepth 2 -maxdepth 2 -type f -name Makefile)
endgroup

group "重建包索引"
# 必须连 stamp 一起删：prepare-tmpinfo 有 scan_unchanged 优化，
# stamp 不删的话索引不会真正重建
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
    for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
      [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
    done
  fi
done
endgroup

group "必装插件硬校验"
# config 里已写 =y 的包都必须出现在这里，否则 defconfig 会静默剔除
CRITICAL_PKGS=(luci-app-airoha-npu)
# 若以后新增必装包，在这里追加，例如：
# CRITICAL_PKGS+=(luci-app-passwall luci-app-mosdns)

[ -f feeds/luci/luci.mk ] || die "feeds/luci/luci.mk 缺失，LuCI app 无法解析"

HARD_MISS=()
for r in "${CRITICAL_PKGS[@]}"; do
  grep -qx "Package: $r" "$PKGINFO" || HARD_MISS+=("$r")
done

if (( ${#HARD_MISS[@]} > 0 )); then
  for m in "${HARD_MISS[@]}"; do
    echo "::error::必装插件 $m 未进索引，defconfig 会静默剔除 =y"
  done
  exit 1
fi
log "  ✅ 必装插件全部就绪: ${CRITICAL_PKGS[*]}"
endgroup

# ================================================================
# 覆盖 feeds/luci 中自带的 dae / honk /openclash
# ================================================================
group "覆盖 feeds/luci 中的 dae / openclash，并将 honk 放入 package/custom"

rm -rf feeds/luci/applications/luci-app-dae
rm -rf feeds/luci/applications/luci-app-openclash
rm -rf feeds/luci/applications/luci-app-honk

clone https://github.com/QiuSimons/luci-app-dae    feeds/luci/applications/luci-app-dae
clone https://github.com/vernesong/OpenClash  feeds/luci/applications/luci-app-openclash
# honk 是容器仓库，含 honk + luci-app-honk 两个包，必须放到 package/custom 下
#clone https://github.com/kenzok8/openwrt-honk.git  feeds/luci/applications/luci-app-honk  "" --depth=1
clone https://github.com/kenzok8/openwrt-honk.git  "$PKG_DIR/honk"  "" --depth=1
# ------------------------------------------------------------------
# honk 仓库的 Makefile 把 PKG_HASH 写成大写 SKIP 占位，
# OpenWrt scripts/download.pl 只识别小写 skip 跳过校验；
# 大写 SKIP 会触发 "Cannot find appropriate hash command ..."。
# 这里把 PKG_HASH / PKG_MIRROR_HASH 的纯 SKIP 占位统一改成 skip。
# 只匹配纯占位行，不会误伤真实哈希。
# ------------------------------------------------------------------
sed -i 's/?=SKIP$/?=skip/' "$PKG_DIR/honk/honk/Makefile"

if [ -d "$PKG_DIR/honk" ]; then
  honk_patched=0
  while IFS= read -r -d '' mkfile; do
    if grep -qE '^[[:space:]]*PKG_(HASH|MIRROR_HASH)[[:space:]]*:?=[[:space:]]*SKIP[[:space:]]*$' "$mkfile"; then
      sed -i -E 's/^([[:space:]]*PKG_(HASH|MIRROR_HASH)[[:space:]]*:?=[[:space:]]*)SKIP[[:space:]]*$/\1skip/' "$mkfile"
      log "  ✏ 修正 $(basename "$(dirname "$mkfile")")/Makefile：PKG_*HASH SKIP → skip"
      honk_patched=$((honk_patched + 1))
    fi
  done < <(find "$PKG_DIR/honk" -type f -name Makefile -print0)
  log "  ✅ honk Makefile 哈希占位修正: ${honk_patched} 处"
fi
endgroup

# ================================================================
# 输出 GitHub Step Summary，Actions 页面直接看结果
# ================================================================
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## diy-part1.sh 执行报告"
    echo ""
    echo "| 项目 | 值 |"
    echo "|---|---|"
    echo "| 启用插件 | ${ENABLED_COUNT} / ${#PKG_LIST[@]} |"
    echo "| 索引缺失 | ${INDEX_MISS[*]:-无} |"
    echo "| 必装校验 | ✅ 通过（${CRITICAL_PKGS[*]}） |"
    echo "| 耗时 | $(( $(date +%s) - SCRIPT_START ))s |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "🎉 diy-part1.sh 执行完毕"
