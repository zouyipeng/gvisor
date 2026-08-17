#!/bin/sh
# bench_fgt.sh — 对比 gVisor systrap 平台 FEAT_FGT 使能 vs 禁用的 syscall 延迟。
#
# 方法：ON/OFF 交替配对测量，逐对计算差值 delta = OFF - ON（ns/call），
# 最后对 ON、OFF、delta 分别取中位数。因为 ON/OFF 走同一个 switch_context
# 交接，delta 会把 stub<->sentry 的 futex 交接噪声抵消掉，只留下 FGT 的
# 固定入口/出口节省。收益 = median_delta / median_OFF * 100%。
#
# 前置：/runsc 与 /syscallbench 已就位（由 build_remote.sh 组装）。
#
# 用法：
#   ./bench_fgt.sh [loops] [pairs]
#   例: ./bench_fgt.sh 1000000 20   # 1M loops，每场景 20 对 ON/OFF
#
# 环境变量覆盖：RUNSC BENCH LOOPS PAIRS

set -u

RUNSC="${RUNSC:-/runsc}"
BENCH="${BENCH:-/syscallbench}"
LOOPS="${1:-1000000}"
PAIRS="${2:-20}"

# runsc 公共参数（与 build_remote.sh 保持一致）。
RUNSC_BASE="--TESTONLY-unsafe-nonroot --rootless --network none --platform=systrap"

# syscallbench 的 syscall 编号（见 syscallbench.c 的 enum syscall_type）。
SYS_GETPID=0
SYS_GETPIDOPT=1

# ---------------------------------------------------------------
# bench_once <cmd...> : 运行一次，解析并输出 "elapsed_ns ns_per_call"
#                       （失败输出空串）。
# ---------------------------------------------------------------
bench_once() {
  "$@" 2>/dev/null | sed -n 's/^# RESULT .*elapsed_ns=\([0-9]*\) ns_per_call=\([0-9.]*\).*/\1 \2/p'
}

# ---------------------------------------------------------------
# median <space-separated numbers> : 输出中位数（偶数个取中间两数均值）。
# ---------------------------------------------------------------
median() {
  echo "$1" | awk '{for (i=1; i<=NF; i++) print $i}' | sort -n | awk '
    {a[NR]=$1}
    END {
      if (NR == 0) { print 0; exit }
      if (NR % 2) print a[(NR+1)/2];
      else printf "%.2f\n", (a[NR/2] + a[NR/2+1]) / 2;
    }'
}

# ---------------------------------------------------------------
# run_pairs <syscall_id> <name>
# 交替跑 PAIRS 对 ON/OFF，逐对打印 delta（stderr，供实时观察），
# 最终向 stdout 输出一行 "<name> <on_median> <off_median> <delta_median>"。
# ---------------------------------------------------------------
run_pairs() {
  local sys="$1" name="$2"
  local i on off delta sgn
  local ons="" offs="" deltas=""

  echo "[$name] 交替测量 ON/OFF，共 $PAIRS 对：" >&2
  for i in $(seq 1 "$PAIRS"); do
    on=$(bench_once "$RUNSC" $RUNSC_BASE do "$BENCH" --loops="$LOOPS" --syscall="$sys" | awk '{print $2}')
    off=$(bench_once "$RUNSC" $RUNSC_BASE --systrap-disable-fgt do "$BENCH" --loops="$LOOPS" --syscall="$sys" | awk '{print $2}')
    if [ -z "$on" ] || [ -z "$off" ]; then
      echo "ERR: $name 第 $i 对测量失败" >&2
      return 1
    fi
    delta=$(awk -v o="$off" -v n="$on" 'BEGIN{printf "%.2f", o-n}')
    sgn="+"
    [ "${delta#-}" != "$delta" ] && sgn=""   # 负数自带负号
    printf "  pair %3d: on=%14s off=%14s delta=%s%s ns/call\n" \
      "$i" "$on" "$off" "$sgn" "$delta" >&2
    ons="$ons $on"
    offs="$offs $off"
    deltas="$deltas $delta"
  done

  local on_med off_med delta_med
  on_med=$(median "$ons")
  off_med=$(median "$offs")
  delta_med=$(median "$deltas")
  echo "" >&2
  printf '%s %s %s %s\n' "$name" "$on_med" "$off_med" "$delta_med"
}

# ---------------------------------------------------------------
echo "===== gVisor systrap FEAT_FGT 对比 (ON vs OFF, 成对差值取中位数) ====="
echo "loops=$LOOPS  pairs=$PAIRS"
echo "kernel: $(uname -r)  machine: $(uname -m)"
echo ""

gp=$(run_pairs "$SYS_GETPID" "getpid") \
    || { echo "getpid 测量失败"; exit 1; }
go=$(run_pairs "$SYS_GETPIDOPT" "getpidopt") \
    || { echo "getpidopt 测量失败"; exit 1; }

# 汇总：每列都是 PAIRS 次的中位数；收益 = delta_med / off_med * 100%。
echo "=== 结果（各 $PAIRS 对，取中位数）==="
awk -v gp="$gp" -v go="$go" '
BEGIN {
  split(gp, a, " ");   # name on_med off_med delta_med
  split(go, b, " ");
  fmt = "  %-12s %14s %14s %14s %10s\n";
  printf fmt, "syscall", "ON ns/call", "OFF ns/call", "Δ (OFF-ON)", "收益";
  printf fmt, "------------", "--------------", "--------------", "--------------", "----------";
  g1 = (a[4] + 0) / (a[3] + 0) * 100;
  g2 = (b[4] + 0) / (b[3] + 0) * 100;
  printf fmt, a[1], a[2], a[3], sprintf("%+.2f", a[4] + 0), sprintf("%+.1f%%", g1);
  printf fmt, b[1], b[2], b[3], sprintf("%+.2f", b[4] + 0), sprintf("%+.1f%%", g2);
}'

echo ""
echo "收益公式: (FGT OFF - FGT ON) / FGT OFF * 100%  (+ 表示 FGT 降低延迟)"
echo "注: Δ 取每对 (OFF-ON) 的中位数，已抵消 futex 交接噪声。"
