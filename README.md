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

```
cargo install --path .
```

Or build a release binary:

```
cargo build --release
```

The binary will be at `target/release/exclawalker`.
