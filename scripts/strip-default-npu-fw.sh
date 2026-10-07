#!/usr/bin/env bash
# ==================================================================
# 把 stock NPU 固件包从 target 的 DEFAULT_PACKAGES / DEVICE_PACKAGES 里摘掉
#
# 为什么必须做：
#   airoha-en7581-npu-firmware 是 airoha/an7581 subtarget 的 DEFAULT_PACKAGE，
#   make defconfig 会把它拉回 =y。于是「ClankerNPU 可选插件包」和 stock 包
#   会同时被装进 rootfs，两个包装的是同一批文件名
#   （/lib/firmware/airoha/<prefix>_npu_{rv32,data}.bin），
#   谁生效取决于安装顺序 —— 不可控。
#
#   摘掉之后，装不装、装哪个完全由 .config 里的 CONFIG_PACKAGE_xxx 决定，
#   可选插件才真的「可选」。包符号本身还在，想用官方固件照样能 =y 勾上
#   （见 workflow 的 7.5 步）。
#
# ⚠️ 关键：DEFAULT_PACKAGES / DEVICE_PACKAGES 是**多行续行**写法：
#
#       DEFAULT_PACKAGES += \
#           airoha-en7581-npu-firmware kmod-nf-conntrack-bridge uboot-envtools
#
#       DEVICE_PACKAGES := kmod-spi-gpio kmod-leds-gpio \
#           kmod-sfp aeonsemi-as21xxx-firmware \
#           kmod-mt7996-firmware airoha-en7581-mt7996-npu-firmware \
#           kmod-usb3
#
#    只按单行匹配会漏掉续行里的 token（实测 an7581/target.mk 第 9 行、
#    image/an7581.mk 第 163 行就漏了），必须跟踪反斜杠续行状态。
#
# 用法：
#   PONWRT_DIR=. ./scripts/strip-default-npu-fw.sh
#   PONWRT_DIR=. STRICT=1 ./scripts/strip-default-npu-fw.sh   # 有残留就 exit 1
# ==================================================================
set -euo pipefail

PONWRT_DIR="${PONWRT_DIR:-.}"
STRICT="${STRICT:-0}"
cd "$PONWRT_DIR"

# 要摘掉的包（linux-firmware 提供的官方 NPU 固件）
STRIP_RE='airoha-[A-Za-z0-9_.-]*npu-firmware'

RC=0
# ------------------------------------------------------------------
# 用 perl 处理：跟踪反斜杠续行，整段摘除
# 输出两件事：
#   [MODIFIED] <文件>
#   [REMOVED ] <行内容>     —— 被改动的行（改动前）
#   [RESIDUAL] <文件>:<行号>:<行内容>  —— 处理完仍在包列表里的残留
# ------------------------------------------------------------------
perl -e '
my $STRIP_RE = qr/airoha-[A-Za-z0-9_.-]*npu-firmware/;
my ($modified, $residual) = (0, 0);

for my $f (@ARGV) {
    open(my $fh, "<", $f) or next;
    local $/; my $c = <$fh>; close $fh;
    my @lines = split(/(?<=\n)/, $c);

    my @out; my @removed; my $in = 0; my $changed = 0; my $ln = 0;
    for my $l (@lines) {
        $ln++;
        my $orig = $l;
        # 进入包列表赋值（含 = := += ?= != 等）
        if ($l =~ /^[ \t]*(?:DEFAULT_PACKAGES|DEVICE_PACKAGES)[ \t]*[+:?!]?=/) {
            $in = 1;
        }
        if ($in && $l =~ /$STRIP_RE/) {
            # 先记下被摘掉的是哪些 token（只摘 npu 固件，其余包原样保留）
            my @tok;
            while ($l =~ /($STRIP_RE)/g) { push @tok, $1; }
            $l =~ s/[ \t]*$STRIP_RE\b//g;
            $changed = 1;
            push @removed, [$ln, join(", ", @tok), $orig, $l];
        }
        # 行尾没有续行反斜杠 -> 这一段结束
        if ($in && $l !~ /\\\s*\n?$/) {
            $in = 0;
        }
        push @out, $l;
    }

    if ($changed) {
        open(my $w, ">", $f) or die "write $f: $!";
        print $w join("", @out); close $w;
        $modified++;
        print "[MODIFIED] $f\n";
        # 注意：[REMOVED] 只列出被摘掉的 token；同一行的其他包不动。
        # 下面 before/after 两行是整行对照，便于确认没误删。
        for my $r (@removed) {
            my ($ln, $tok, $before, $after) = @$r;
            chomp $before; chomp $after;
            print "[REMOVED ] $f:$ln -> $tok\n";
            print "   before| $before\n";
            print "   after | $after\n";
        }
    }

    # 残留复核：整段重新扫一遍，看还有没有落在包列表里的 token
    my $ln = 0; my $in2 = 0;
    for my $l (@out) {
        $ln++;
        $in2 = 1 if $l =~ /^[ \t]*(?:DEFAULT_PACKAGES|DEVICE_PACKAGES)[ \t]*[+:?!]?=/;
        if ($in2 && $l =~ /$STRIP_RE/) {
            chomp $l; print "[RESIDUAL] $f:$ln:$l\n"; $residual++;
        }
        $in2 = 0 if $in2 && $l !~ /\\\s*\n?$/;
    }
}

print "[SUMMARY] modified=$modified residual=$residual\n";
exit($residual > 0 ? 3 : 0);
' $(grep -rlE '(DEFAULT_PACKAGES|DEVICE_PACKAGES)' target/ 2>/dev/null || true) || RC=$?

# perl 用 3 表示「有残留」（与 grep 无匹配导致的退出码区分开）
if [ "$RC" = "3" ]; then
  echo "::error::仍有 stock NPU 固件残留在 DEFAULT_PACKAGES / DEVICE_PACKAGES 里（见 [RESIDUAL] 行）"
  [ "$STRICT" = "1" ] && exit 1
elif [ "$RC" != "0" ]; then
  echo "::warning::摘除脚本退出码 $RC（未匹配到任何 target 文件？）"
fi

# ------------------------------------------------------------------
# 诊断：源码里还有哪些地方提到 stock NPU 固件
#   分两类，别一锅端：
#     ① 包列表（DEFAULT_PACKAGES / DEVICE_PACKAGES）—— 必须清空，已由上面处理
#     ② package/firmware/linux-firmware/airoha.mk 里的包定义 —— 正常且必须保留，
#        那是 stock 固件的包符号来源（npu_fw=stock 还要靠它）
#     ③ patch 里的 URL —— 无关
# ------------------------------------------------------------------
echo ""
echo "----- 残留诊断：源码里还有哪些地方提到 stock NPU 固件 -----"
grep -rnE "$STRIP_RE" target/ package/ 2>/dev/null \
  | grep -vE 'patch' \
  | grep -vE 'package/firmware/linux-firmware/airoha\.mk' \
  || echo "  无（DEFAULT_PACKAGES / DEVICE_PACKAGES 已摘干净）"

echo ""
echo "----- 参考：linux-firmware 里的包定义（保留，stock 模式要用）-----"
grep -nE "^\s*Package/${STRIP_RE}\s*=" package/firmware/linux-firmware/airoha.mk 2>/dev/null \
  || echo "  未找到（ponwrt 可能换了路径）"
