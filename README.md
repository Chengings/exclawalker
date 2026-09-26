# exclawalker

Prepend `!` to each character from stdin — for lazy [fzf](https://github.com/junegunn/fzf) users who don't want to hold SHIFT.

## Why

fzf uses `!` to negate/exclude matches. When solving wordle puzzles, I often need to
exclude several characters at once. Typing `!a !e !t` by hand means hitting SHIFT for
every single `!`. exclawalker does it for me.

## Usage

```
echo "aet" | exclawalker
# !a !e !t
```

Pipe directly to clipboard for use with fzf:

```
exclawalker | pbcopy
```

Then type the characters you want to exclude (e.g. `aet`), press Enter, and paste
the result (`!a !e !t`) into fzf.

## Install

Needs [just](https://github.com/casey/just). Builds the release binary and installs
it to `~/.local/bin`, or to `/usr/local/bin` with `sudo` if that isn't writable:

```
just install
```

Or install the assembly port instead (arm64 macOS or aarch64 Linux):

```
just asm-install
```

Both install as `exclawalker`, so the second replaces the first. Pass a name to
keep both, for example `just asm-install exclawalker-asm`.

Avoid `cargo install --path .` alongside these: it installs to `~/.cargo/bin`, and
whichever directory comes first in `PATH` silently wins.

Or build a release binary without installing:

```
cargo build --release
```

The binary will be at `target/release/exclawalker`.
