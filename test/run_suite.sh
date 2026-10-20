#!/bin/sh
# run_suite.sh [core|chip] [CACHE=1] [REV2=1|PACK=1] - the SDCC test suite's
# self-checking programs (lisa-tools/sdcc_test/*.ihx) on the core-level or the
# chip-level testbench; one line per program, PASS/FAIL.  REV2=1 runs the
# suite built with sdcc --rev2 (*_rev2.ihx, `make check REV2=1` there): the
# stack convention of this RTL since 2026-10-17 - the TT07 build's frames
# are one byte off on it.
# Without CACHE=1 the data space is the 128-byte RAM: the programs that need
# the 32K (test_bigframe, test_ptroff: built with --stack-loc 0x7fff) are in
# the CACHE=1 list only, with the TT07 cache tests (which have no --rev2 build).
where=${1:-chip}
shift
sfx=
case "$*" in *REV2=1*) sfx=_rev2; set -- $(printf '%s\n' "$@" | grep -v '^REV2=');; esac
# PACK=1: the suite built with sdcc --pack-const (*_rev2k.ihx, `make check PACK=1`
# there): constants packed two to a word and read with lda (ix++) (RESPIN 26)
case "$*" in *PACK=1*) sfx=_rev2k; set -- $(printf '%s\n' "$@" | grep -v '^PACK=');; esac
# REV3=1: the suite built with sdcc --rev3 (*_rev3.ihx, `make check REV3=1`
# there): the third chip's 24-bit pointers and three-byte pairs (REV3.md),
# the stack at 2 MB - so the cache (the PSRAM) is always on, and every
# program runs in the one list
rev3=
case "$*" in *REV3=1*) sfx=_rev3; rev3=1; set -- CACHE=1 $(printf '%s\n' "$@" | grep -v '^REV3=\|^CACHE=');; esac
SDCC_TEST=${SDCC_TEST:-$(cd "$(dirname "$0")/../../lisa-tools/sdcc_test" && pwd)}
SELFCHECK="test_core test_negate test_union test_varargs test_digits test_signed test_strs test_regress test_pfu test_loop test_irq test_irq2 test_divsh test_divl test_bf16 test_bf16f test_rot test_index test_vshift"
BIGDATA="test_bigframe test_ptroff"
# rev 2 only: RMW on a miss with evictions 0x80 apart (this cache's 8 lines;
# test_cachermw's 0x40 never misses here)
# and the ldirq / stirq round trip through the shadows (RESPIN 24), the divider's
# two results and the chained step divc (RESPIN 27)
REV2CACHE="test_cachermw8 test_ldirq test_uartirq test_ldk test_divc test_bank test_dbank test_irqcache"
CACHE_TESTS="test_cacherm test_cachermw test_cachepush test_cachewb test_cacheseq test_cacheloop test_cacheperiph"
# rev 3: the second chip's list less its bank registers (test_ldk, test_dbank), plus the huge model and its own test
REV3CACHE="test_cachermw8 test_ldirq test_uartirq test_divc test_bank test_huge test_rev3c"
if [ -n "$rev3" ]; then list="$SELFCHECK $BIGDATA $REV3CACHE"; else
case "$*" in *CACHE=1*) list="$(test -n "$sfx" && echo $REV2CACHE || echo $CACHE_TESTS) $BIGDATA";; *) list="$SELFCHECK";; esac
fi
dir=$(dirname "$0"); [ "$where" = core ] && dir="$dir/core"
pass=0; fail=0
for t in $list; do
  extra=
  case "$t" in
    test_uartirq)                      # the bench types "Hi" once the program runs (RESPIN 25)
      [ "$where" = core ] && { echo "SKIP $t (the core testbench has no UART)"; continue; }
      extra="SEND=Hi SEND_DELAY=400000";;
  esac
  out=$(cd "$dir" && make IHX="$SDCC_TEST/$t$sfx.ihx" TIMEOUT=${TIMEOUT:-6000000} $extra "$@" 2>&1)
  if printf '%s' "$out" | grep -q "test_program *PASS"; then
    echo "PASS $t"; pass=$((pass+1))
  else
    echo "FAIL $t"; printf '%s\n' "$out" | grep "LISA\] \(FAIL\|SOME\)\|Timeout\|rror" | head -5; fail=$((fail+1))
  fi
done
echo "$pass passed, $fail failed ($where $*)"
