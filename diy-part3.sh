#!/bin/bash
# ============================================================
# diy-part3.sh —— 中文翻译白名单精简脚本
# 功能：
#   1) 强制保证 CONFIG_LUCI_LANG_zh_Hans=y
#   2) 关闭所有 luci-i18n-*-zh-cn 翻译包
#   3) 仅放行白名单内的翻译
# 用法：必须在 OpenWrt 源码根目录下运行（.config 已就位）
# ============================================================
set -e

# ---------- 可按需修改的白名单 ----------
KEEP="base package-manager"   # 要保留中文翻译的组件
# 需要临时多留几个时也可以用环境变量追加：KEEP_EXTRA="ddns-go" bash diy-part3.sh
KEEP="$KEEP ${KEEP_EXTRA:-}"
# ---------------------------------------

LANG_SYM="CONFIG_LUCI_LANG_zh_Hans"

echo ">>> [1/5] 强制开启简体中文语言开关 (${LANG_SYM}=y)"
sed -i "s|^# ${LANG_SYM} is not set|${LANG_SYM}=y|" .config
sed -i "s|^${LANG_SYM}=m|${LANG_SYM}=y|"            .config
grep -q "^${LANG_SYM}=y$" .config || echo "${LANG_SYM}=y" >> .config

echo ">>> [2/5] 执行 make defconfig，物化所有已选应用的翻译包"
# 此时所有 luci-i18n-*-zh-cn 会按 DEFAULT:=LUCI_LANG_zh_Hans 自动变为 =y
make defconfig

echo ">>> [3/5] 关闭全部中文翻译包（含 y/m 两种状态）"
sed -i -E 's/^(CONFIG_PACKAGE_luci-i18n-[a-zA-Z0-9_-]+-zh-cn)=(y|m)/# \1 is not set/' .config

echo ">>> [4/5] 放行白名单翻译: ${KEEP}"
for name in $KEEP; do
    [ -z "$name" ] && continue
    sym="CONFIG_PACKAGE_luci-i18n-${name}-zh-cn"
    grep -q "^${sym}=y$" .config || echo "${sym}=y" >> .config
done

echo ">>> [5/5] 再次 defconfig：解析白名单翻译的依赖关系"
# 显式的 "is not set" 属于用户值，不会被 DEFAULT 重新拉起；
# 白名单条目若依赖的应用未选，会在此步被自动补齐
make defconfig

# ---------- 校验 ----------
echo ""
echo "===== 校验结果 ====="
echo "-- 语言开关："
grep "^${LANG_SYM}=" .config || { echo "错误：${LANG_SYM} 丢失！"; exit 1; }

echo "-- 固件内将包含的中文翻译："
grep -E '^CONFIG_PACKAGE_luci-i18n-[a-zA-Z0-9_-]+-zh-cn=y' .config | sed 's/CONFIG_PACKAGE_//;s/=y//' || echo "(无)"

BAD=$(grep -E '^CONFIG_PACKAGE_luci-i18n-[a-zA-Z0-9_-]+-zh-cn=y' .config \
      | grep -vE "luci-i18n-($(echo $KEEP | tr ' ' '|'))-zh-cn" || true)
if [ -n "$BAD" ]; then
    echo "错误：白名单之外仍有残留："
    echo "$BAD"
    exit 1
fi
echo "✔ 校验通过：白名单之外无任何中文翻译"
