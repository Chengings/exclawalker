# Binary name from Cargo.toml
binary_name := "exclawalker"

# Run all tests
test:
    cargo test

# Fast check (no binary produced)
check:
    cargo check

# Debug build
build:
    cargo build

# Release build
release:
    cargo build --release

# Run the programme
run:
    cargo run

# Format code
fmt:
    cargo fmt

# Lint with clippy
clippy:
    cargo clippy

# Clean build artefacts
clean:
    cargo clean

# Build the assembly port for this platform (arm64 macOS)
[macos]
asm:
    mkdir -p target/asm
    clang -arch arm64 -Wl,-x -Wl,-dead_strip -o target/asm/{{binary_name}} asm/{{binary_name}}-macos.s

# Build the assembly port for this platform (aarch64 Linux, static)
[linux]
asm:
    @test "$(uname -m)" = aarch64 || { echo "asm: the Linux port is AArch64-only; this machine is $(uname -m)" >&2; exit 1; }
    mkdir -p target/asm
    as -o target/asm/{{binary_name}}.o asm/{{binary_name}}-linux.s
    ld -static -s -o target/asm/{{binary_name}} target/asm/{{binary_name}}.o

# Install the Rust binary to ~/.local/bin or fallback to /usr/local/bin
install: release (_install "target/release" / binary_name binary_name)

# Copy SRC to ~/.local/bin/NAME, or to /usr/local/bin/NAME with sudo.
# `install` rather than `cp`: on macOS it writes a new file and renames it into
# place, whereas `cp` overwrites in place, and a signed binary rewritten in place
# can be killed at launch (the kernel caches its signature per file).
_install src name:
    #!/usr/bin/env sh
    set -eu
    LOCAL_BIN="$HOME/.local/bin"
    SYSTEM_BIN="/usr/local/bin"

    # Try to create and use ~/.local/bin
    if mkdir -p "$LOCAL_BIN" 2>/dev/null && [ -w "$LOCAL_BIN" ]; then
        install -m 755 "{{src}}" "$LOCAL_BIN/{{name}}"
        echo "Installed {{src}} as $LOCAL_BIN/{{name}}"
        echo "Make sure $LOCAL_BIN is in your PATH"
    else
        echo "Cannot use $LOCAL_BIN, falling back to $SYSTEM_BIN (requires sudo)"
        sudo install -m 755 "{{src}}" "$SYSTEM_BIN/{{name}}"
        echo "Installed {{src}} as $SYSTEM_BIN/{{name}}"
    fi
