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

# Install the binary to ~/.local/bin or fallback to /usr/local/bin
install: release
    #!/usr/bin/env sh
    set -eu
    BINARY="target/release/{{binary_name}}"
    LOCAL_BIN="$HOME/.local/bin"
    SYSTEM_BIN="/usr/local/bin"

    # Try to create and use ~/.local/bin
    if mkdir -p "$LOCAL_BIN" 2>/dev/null && [ -w "$LOCAL_BIN" ]; then
        cp "$BINARY" "$LOCAL_BIN/{{binary_name}}"
        echo "Installed {{binary_name}} to $LOCAL_BIN"
        echo "Make sure $LOCAL_BIN is in your PATH"
    else
        echo "Cannot use $LOCAL_BIN, falling back to $SYSTEM_BIN (requires sudo)"
        sudo cp "$BINARY" "$SYSTEM_BIN/{{binary_name}}"
        echo "Installed {{binary_name}} to $SYSTEM_BIN"
    fi
