SHELL := /bin/zsh

RUST_TARGETS := x86_64-apple-darwin aarch64-apple-darwin
RUST_CRATE := macord-ffi

.PHONY: all build test check run fmt lint clean rust-build swift-build universal

all: check

build: rust-build swift-build

check: test swift-build

test:
	cargo test --workspace

rust-build:
	cargo build --workspace --release

swift-build:
	swift build -c release

run: rust-build
	swift run

fmt:
	cargo fmt --all

lint:
	cargo clippy --workspace --all-targets --all-features -- -D warnings

universal:
	rustup target add $(RUST_TARGETS)
	cargo build -p $(RUST_CRATE) --release --target x86_64-apple-darwin
	cargo build -p $(RUST_CRATE) --release --target aarch64-apple-darwin
	mkdir -p target/universal/release
	lipo -create \
		target/x86_64-apple-darwin/release/lib$(RUST_CRATE).a \
		target/aarch64-apple-darwin/release/lib$(RUST_CRATE).a \
		-output target/universal/release/lib$(RUST_CRATE).a

clean:
	cargo clean
	rm -rf .build
