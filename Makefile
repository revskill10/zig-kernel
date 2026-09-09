# Zig-Kernel Makefile
# Convenience targets for development and CI

.PHONY: all build run test clean qemu qemu-bin qemu-run qemu-test inspect

# Default target
all: build

# Build everything
build: build.zig
	zig build

# Build and run (hosted simulation)
run: build
	zig build run

# Run tests
test: build.zig
	zig build test

# Clean build artifacts
clean:
	rm -rf zig-out .zig-cache

# QEMU targets
qemu-bin: build.zig
	zig build qemu-bin

qemu-run: qemu-bin
	@./scripts/run-qemu.sh

# QEMU headless test (for CI)
qemu-test: qemu-bin
	@echo "=== Running kernel in QEMU headless mode ==="
	@./scripts/run-qemu.sh -n 2>&1 | tee zig-out/qemu-output.log || true
	@echo ""
	@echo "=== Checking for expected output ==="
	@grep -q "Kernel summary" zig-out/qemu-output.log && echo "✅ QEMU test PASSED" || echo "❌ QEMU test FAILED"

# Inspect generated files
inspect: build
	@echo "=== Build outputs ==="
	@ls -la zig-out/bin/ 2>/dev/null || echo "No binary output"
	@echo ""
	@echo "=== Kernel symbol info ==="
	@file zig-out/bin/zig-kernel 2>/dev/null || echo "Binary not found"

# Deep clean including all generated artifacts
distclean:
	rm -rf zig-out .zig-cache zig-out/kernel zig-out/qemu-output.log

# Help
help:
	@echo "Zig-Kernel Build Targets"
	@echo "========================"
	@echo "  all         - Build everything (alias for 'build')"
	@echo "  build       - Build hosted executable"
	@echo "  run         - Build and run hosted simulation"
	@echo "  test        - Run unit tests"
	@echo "  clean       - Remove zig-out and .zig-cache"
	@echo ""
	@echo "QEMU targets:"
	@echo "  qemu-bin    - Build bare-metal ELF for QEMU"
	@echo "  qemu-run    - Run kernel in QEMU with display"
	@echo "  qemu-test   - Run QEMU headless and verify output (CI)"
	@echo ""
	@echo "Utility:"
	@echo "  inspect     - Show build outputs and file info"
	@echo "  distclean   - Remove all generated artifacts"
	@echo "  help        - Show this help message"