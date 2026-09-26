#!/usr/bin/env bash
# Benchmark the assembly port against the Rust release build.
# Results go to target/bench/. See docs/asm-port.md.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
case $(uname -s) in
Darwin) platform=macos ;;
Linux) platform=linux ;;
*) echo "unsupported OS: $(uname -s)" >&2; exit 2 ;;
esac
RUST=${RUST:-target/release/exclawalker}
ASM=${ASM:-target/asm/exclawalker}
RUNS=${RUNS:-2000}
INCAP=$(awk '$1 == ".equ" && $2 == "INCAP," { print $3 }' "$here/exclawalker-$platform.s")
[[ $INCAP =~ ^[0-9]+$ ]] || { echo "cannot read INCAP from exclawalker-$platform.s" >&2; exit 2; }
out=target/bench
mkdir -p "$out"

printf 'aeiou\n' >"$out/small.txt"
head -c 1024 /dev/zero | tr '\0' a >"$out/1k.txt"
head -c "$INCAP" /dev/zero | tr '\0' a >"$out/max.txt" # longest line the assembly accepts

for f in small 1k max; do
	cmp -s <("$RUST" <"$out/$f.txt") <("$ASM" <"$out/$f.txt") || { echo "outputs differ on $f" >&2; exit 1; }
	hyperfine -N --warmup 100 --runs "$RUNS" --input "$out/$f.txt" \
		--export-json "$out/$f.json" --export-markdown "$out/$f.md" \
		-n rust "$RUST" -n asm "$ASM"
done

# median FILE COLUMN — median of a numeric column over an odd number of rows.
median() { cut -d' ' -f"$2" "$1" | sort -n | awk '{v[NR] = $1} END {print v[(NR + 1) / 2]}'; }

if [[ $platform == macos ]]; then
	echo "== peak memory and instructions retired (small input, median of 21 runs each)"
	for bin in "$RUST" "$ASM"; do
		for _ in {1..21}; do
			/usr/bin/time -l "$bin" <"$out/small.txt" 2>&1 >/dev/null |
				awk '/maximum resident/ {r=$1} /instructions retired/ {i=$1} END {print r, i}'
		done >"$out/time-l.txt"
		printf '%-28s peak RSS %6.0f KiB  instructions %d\n' "$bin" \
			"$(($(median "$out/time-l.txt" 1) / 1024))" "$(median "$out/time-l.txt" 2)"
	done
else
	# Peak RSS is not measured on Linux: getrusage's child maxrss includes the
	# launcher's pre-exec memory (exec folds the old mm's high-water mark into it),
	# so a small program run from Python or bash reads as big as its parent. No GNU
	# time or perf on a stock Pi OS either.
	echo "== peak memory: not measured on Linux (see comment in bench.sh)"
fi
