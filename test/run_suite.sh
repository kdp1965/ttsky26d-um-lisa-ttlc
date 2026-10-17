#!/bin/sh
# run_suite.sh [core|chip] [CACHE=1] [REV2=1] - the SDCC test suite's
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
SDCC_TEST=${SDCC_TEST:-$(cd "$(dirname "$0")/../../lisa-tools/sdcc_test" && pwd)}
SELFCHECK="test_core test_negate test_union test_varargs test_digits test_signed test_strs test_regress test_pfu test_loop test_irq test_irq2 test_divsh test_divl test_bf16 test_bf16f test_rot test_index test_vshift"
BIGDATA="test_bigframe test_ptroff"
CACHE_TESTS="test_cacherm test_cachermw test_cachepush test_cachewb test_cacheseq test_cacheloop test_cacheperiph"
case "$*" in *CACHE=1*) list="$(test -n "$sfx" || echo $CACHE_TESTS) $BIGDATA";; *) list="$SELFCHECK";; esac
dir=$(dirname "$0"); [ "$where" = core ] && dir="$dir/core"
pass=0; fail=0
for t in $list; do
  out=$(cd "$dir" && make IHX="$SDCC_TEST/$t$sfx.ihx" TIMEOUT=${TIMEOUT:-6000000} "$@" 2>&1)
  if printf '%s' "$out" | grep -q "test_program *PASS"; then
    echo "PASS $t"; pass=$((pass+1))
  else
    echo "FAIL $t"; printf '%s\n' "$out" | grep "LISA\] \(FAIL\|SOME\)\|Timeout\|rror" | head -5; fail=$((fail+1))
  fi
done
echo "$pass passed, $fail failed ($where $*)"
