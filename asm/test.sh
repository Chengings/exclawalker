#!/usr/bin/env bash
# SC2016: command templates expand later, inside `bash -c`.
# SC2059: printf formats are built on purpose to emit escape sequences.
# shellcheck disable=SC2016,SC2059
# Differential tests: the assembly port against the Rust release build.
# Each case feeds identical stdin to both binaries and compares stdout byte for
# byte plus the exit code. See docs/asm-port.md.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
case $(uname -s) in
Darwin) platform=macos ;;
Linux) platform=linux ;;
*) echo "unsupported OS: $(uname -s)" >&2; exit 2 ;;
esac
src=$here/exclawalker-$platform.s
RUST=${RUST:-target/release/exclawalker}
ASM=${ASM:-target/asm/exclawalker}
FUZZ_ITERS=${FUZZ_ITERS:-2000}
# equ NAME — value of `.equ NAME, <integer>` in the assembly source.
equ() {
	local v
	v=$(awk -v n="$1," '$1 == ".equ" && $2 == n { print $3 }' "$src")
	[[ $v =~ ^[0-9]+$ ]] || { echo "cannot read $1 from $src" >&2; exit 2; }
	echo "$v"
}
INCAP=$(equ INCAP)
READ_CHUNK=$(equ READ_CHUNK)

work=$(mktemp -d "${TMPDIR:-/tmp}/exclawalker-test.XXXXXX")
# Counters live in files: `printf … | check` runs check in a subshell.
: >"$work/pass"
: >"$work/fail"
ok() { echo >>"$work/pass"; }
bad() {
	echo >>"$work/fail"
	printf 'FAIL %s\n' "$1"
}
count() { wc -l <"$work/$1" | tr -d ' '; }

# dump LABEL FILE — first bytes of FILE, escaped. od -N rather than `| head`,
# which would SIGPIPE od and abort the script under pipefail.
dump() { printf '  %-5s' "$1:"; od -An -c -N 96 "$2" | tr -s ' ' | paste -sd ' ' -; }

# run BIN IN TEMPLATE OUT — run TEMPLATE with $BIN, $IN, $SHIM and $SHIMLOG
# (OUT.shimlog) set; print exit code.
run() {
	local rc=0
	BIN=$1 IN=$2 SHIM=$work/shortio SHIMLOG=$4.shimlog \
		bash -o pipefail -c "$3" >"$4" 2>/dev/null || rc=$?
	echo "$rc"
}

# check_cmd NAME TEMPLATE [INPUT] — both binaries must agree on stdout and exit code.
check_cmd() {
	local name=$1 tmpl=$2 in=${3:-/dev/null} r a
	r=$(run "$RUST" "$in" "$tmpl" "$work/r.out")
	a=$(run "$ASM" "$in" "$tmpl" "$work/a.out")
	if [[ $r == "$a" ]] && cmp -s "$work/r.out" "$work/a.out"; then
		ok
		return
	fi
	bad "$name (exit: rust=$r asm=$a)"
	dump rust "$work/r.out"
	dump asm "$work/a.out"
	if [[ $in != /dev/null ]]; then
		local kept
		kept=$work/fail-$(count fail).in
		cp "$in" "$kept"
		printf '  input kept: %s\n' "$kept"
	fi
}

# check NAME — stdin is the test input.
check() {
	cat >"$work/in"
	check_cmd "$1" '"$BIN" <"$IN"' "$work/in"
}

# check_shim NAME — like check, but with short reads, short writes and injected
# EINTR (asm/shortio-macos.c or asm/shortio-linux.c). Also asserts from each
# binary's log that these actually happened, so a shim that silently fails to
# load can't pass.
check_shim() {
	cat >"$work/in"
	: >"$work/r.out.shimlog"
	: >"$work/a.out.shimlog"
	check_cmd "$1 [shim]" "$shim_run" "$work/in"
	local who log
	for who in r a; do
		log=$(<"$work/$who.out.shimlog")
		if [[ $log == *r* && $log == *w* && $log == *i* ]]; then
			ok
		else
			bad "$1 [shim] not exercised for $who (log: ${log:0:40})"
		fi
	done
}

# expect NAME TEMPLATE INPUT RUST_RC ASM_RC ASM_BYTES — assert a known divergence:
# exit codes for both, and the exact stdout size for the assembly.
expect() {
	local r a n
	r=$(run "$RUST" "$3" "$2" /dev/null)
	a=$(run "$ASM" "$3" "$2" "$work/a.out")
	n=$(wc -c <"$work/a.out" | tr -d ' ')
	if [[ $r == "$4" && $a == "$5" && $n == "$6" ]]; then
		ok
	else
		bad "$1 (rust exit $r, asm exit $a with $n bytes; expected $4, $5 with $6 bytes)"
	fi
}

repeat() { # repeat CHAR COUNT
	head -c "$2" /dev/zero | tr '\0' "$1"
}

echo "== binary checks ($platform)"
# Tool output is captured before searching: a pipe into `grep -q` can SIGPIPE the
# producer and hide a match under pipefail.
if [[ $platform == macos ]]; then
	clang -arch arm64 -O2 -dynamiclib -o "$work/shortio" "$here/shortio-macos.c"
	shim_run='SHORTIO_LOG="$SHIMLOG" DYLD_INSERT_LIBRARIES="$SHIM" "$BIN" <"$IN"'
	libs=$(otool -L "$ASM" | tail -n +2 | awk '{print $1}')
	if [[ $libs == /usr/lib/libSystem.B.dylib ]]; then ok; else bad "links more than libSystem: $libs"; fi
	disasm=$(otool -tv "$ASM")
	if codesign -v "$ASM" 2>/dev/null; then ok; else bad "invalid code signature"; fi
else
	cc -O2 -Wall -Wextra -Werror -o "$work/shortio" "$here/shortio-linux.c"
	shim_run='SHORTIO_LOG="$SHIMLOG" "$SHIM" "$BIN" <"$IN"'
	elf=$(readelf -hlW "$ASM")
	if grep -q 'Type: *EXEC' <<<"$elf"; then ok; else bad "not a static executable"; fi
	if grep -q INTERP <<<"$elf"; then bad "has a dynamic loader (INTERP)"; else ok; fi
	if grep -q 'GNU_STACK.* RW ' <<<"$elf"; then ok; else bad "stack is executable or unmarked"; fi
	disasm=$(objdump -d "$ASM")
fi
[[ -n $disasm ]] || { echo "no disassembly produced" >&2; exit 2; }
if grep -Eqw 'x18|w18' <<<"$disasm"; then bad "uses x18 (reserved on Apple platforms; both ports avoid it)"; else ok; fi

echo "== cases from src/lib.rs"
printf '123' | check numbers
printf 'abc' | check strings
printf '' | check empty
printf 'abc  ' | check trailing-whitespace
printf 'a\tb\n' | check control-chars
printf 'x' | check single-char

echo "== input handling"
printf 'aet\n' | check readme-example
printf 'ab' | check no-trailing-newline
printf 'ab\ncd\n' | check first-line-only
printf '\nab\n' | check empty-first-line
printf 'ab\r\n' | check crlf
check_cmd closed-stdin '"$BIN" <&-'
check_cmd dir-stdin '"$BIN" </'
check_cmd slow-writer '(printf a; sleep 0.1; printf b; sleep 0.1; printf "c\nd") | "$BIN"'
# What a later reader of the same stdin sees must match: both read in 8 KiB chunks.
{ printf 'ab\n'; repeat x 20000; } >"$work/rest"
check_cmd leftover-stdin-short-line '{ "$BIN" >/dev/null; cat; } <"$IN"' "$work/rest"
{ repeat y 20000; printf '\n'; repeat x 20000; } >"$work/rest-long"
check_cmd leftover-stdin-long-line '{ "$BIN" >/dev/null; cat; } <"$IN"' "$work/rest-long"

echo "== whitespace"
printf '  ab\n' | check leading
printf 'a b\tc\n' | check inner
printf ' \t \n' | check all-whitespace
for ws in ' ' '\t' '\v' '\f' '\r'; do
	printf "a${ws}b${ws}" | check "trailing-$ws"
done
printf 'a\x1c\x1f\n' | check non-whitespace-controls # Rust's is_whitespace excludes these

echo "== byte coverage"
printf 'a\0b\n' | check nul
printf '!!\n' | check bang
for i in {0..127}; do
	((i == 10)) || printf "\\$(printf %03o "$i")"
done | check all-ascii

echo "== buffer limits (INCAP=$INCAP)"
repeat a $((INCAP - 1)) | check "input-$((INCAP - 1))"
repeat a "$INCAP" | check "input-$INCAP"
{ repeat a "$INCAP"; printf '\n'; } | check "input-$INCAP-with-newline"
{ repeat a "$INCAP"; printf '\nmore'; } | check "input-$INCAP-then-next-line"
# The limit applies after trimming, so trailing whitespace past it is fine.
{ repeat a "$INCAP"; printf '\r\n'; } | check "input-$INCAP-crlf"
{ repeat a "$INCAP"; printf ' '; } | check "input-$INCAP-trailing-space-eof"
{ repeat a "$INCAP"; repeat ' ' 20000; printf '\n'; } | check "input-$INCAP-long-trailing-whitespace"
{ repeat ' ' 100000; printf '\n'; } | check long-all-whitespace-line
# What a later reader sees must also match at the limit, where the last read
# starts with less than a chunk of room left.
{ repeat a "$INCAP"; printf '\n'; repeat x 20000; } >"$work/rest-limit"
check_cmd leftover-stdin-at-limit '{ "$BIN" >/dev/null; cat; } <"$IN"' "$work/rest-limit"
{ repeat a "$INCAP"; repeat ' ' 20000; printf '\n'; repeat x 20000; } >"$work/rest-ws"
check_cmd leftover-stdin-after-dropped-whitespace '{ "$BIN" >/dev/null; cat; } <"$IN"' "$work/rest-ws"

echo "== short reads, short writes, EINTR"
printf 'hello world\nx' | check_shim hello
printf '  a b \t\r\n' | check_shim whitespace
{ repeat a $((INCAP - 1)); printf ' \n'; } | check_shim longest-line-trailing-space
{ repeat a "$INCAP"; repeat ' ' 9000; printf '\n'; } | check_shim dropped-trailing-whitespace

echo "== known divergences"
repeat a "$INCAP" >"$work/big"
{ repeat a $((INCAP + 1)); printf '\n'; } >"$work/over"
expect over-limit '"$BIN" <"$IN"' "$work/over" 0 1 0
{ repeat a $((INCAP - 10)); repeat ' ' 20000; printf 'b\n'; } >"$work/over-ws"
expect over-limit-inner-whitespace '"$BIN" <"$IN"' "$work/over-ws" 0 1 0
# Content right after the first whitespace drop, while the kept length is still
# within INCAP: only the dropped-whitespace check (x24) can reject this. The first
# drop happens at the first READ_CHUNK multiple past INCAP; `b` lands 5 bytes into
# the next read.
drop_at=$(((INCAP / READ_CHUNK + 1) * READ_CHUNK))
{ repeat a $((INCAP - 10)); repeat ' ' $((drop_at - (INCAP - 10) + 5)); printf 'b\n'; } >"$work/after-drop"
expect content-after-dropped-whitespace '"$BIN" <"$IN"' "$work/after-drop" 0 1 0
# Same, but more whitespace follows `b` and forces a second drop before the
# newline: the check at the second drop has to catch it.
{ repeat a $((INCAP - 10)); repeat ' ' $((drop_at - (INCAP - 10) + 5)); printf b; repeat ' ' "$READ_CHUNK"; printf '\n'; } >"$work/between-drops"
expect content-between-dropped-whitespace '"$BIN" <"$IN"' "$work/between-drops" 0 1 0
# The reader is gone before input arrives, so the write always hits a closed pipe.
# (Filling the pipe instead is unreliable: 16 KiB-page kernels such as the Pi 5's
# have 256 KiB pipe buffers, larger than the biggest possible output.)
expect epipe '{ sleep 0.2; cat "$IN"; } | "$BIN" | true' "$work/big" 134 141 0
# A parent that ignores SIGPIPE must not change the outcome (the port resets it).
expect epipe-sigpipe-ignored 'trap "" PIPE; { sleep 0.2; cat "$IN"; } | "$BIN" | true' "$work/big" 134 141 0

# gen LEN WS — random ASCII line; WS=1 uses a whitespace-heavy alphabet to exercise
# the trimming paths. The closing head makes tr exit 141, hence `|| true`.
gen() {
	(($1)) || return 0 # macOS head rejects -c 0
	if (($2)); then
		head -c $(($1 * 50 + 1)) /dev/urandom | LC_ALL=C tr -dc ' \t\v\f\r\nab' | head -c "$1" || true
	else
		head -c $(($1 * 2 + 1)) /dev/urandom | LC_ALL=C tr -dc '\000-\177' | head -c "$1" || true
	fi
}

echo "== fuzz ($FUZZ_ITERS iterations)"
for ((i = 0; i < FUZZ_ITERS; i++)); do
	gen $((RANDOM % 301)) $((i % 2)) | check "fuzz-$i"
done

printf '\n%d passed, %d failed\n' "$(count pass)" "$(count fail)"
(($(count fail) == 0)) || { echo "work dir: $work"; exit 1; }
