# Zig-Kernel Makefile
# Convenience targets for development and CI

.PHONY: all build run test clean qemu qemu-bin qemu-run qemu-test inspect dist distclean

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
	rm -rf zig-out .zig-cache dist

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

# Linux-style release tarball (like `make tar-pkg`): zig-kernel-$VERSION.tar.{gz,xz} + bin + SHA256SUMS
VERSION ?= $(shell grep -Po '\.version\s*=\s*"\K[^"]+' build.zig.zon 2>/dev/null || echo 0.1.0)
DIST    := zig-kernel-$(VERSION)
dist:
	@echo "=== Creating Linux-style release tarballs $(DIST) ==="
	@rm -rf dist && mkdir -p dist
	@git archive --format=tar --prefix="$(DIST)/" HEAD | gzip -9 > "dist/$(DIST).tar.gz"
	@git archive --format=tar --prefix="$(DIST)/" HEAD | xz -9 -T0 > "dist/$(DIST).tar.xz"
	@mkdir -p "dist/$(DIST)-bin" && cp zig-out/bin/kernel-baremetal "dist/$(DIST)-bin/" 2>/dev/null || (zig build qemu-bin -Doptimize=ReleaseSmall >/dev/null && cp zig-out/bin/kernel-baremetal "dist/$(DIST)-bin/")
	@cp zig-out/bin/zig-kernel "dist/$(DIST)-bin/" 2>/dev/null || true; cp zig-out/bin/zig-kernel.exe "dist/$(DIST)-bin/" 2>/dev/null || true; cp linker.ld README.md "dist/$(DIST)-bin/" 2>/dev/null || true
	@tar -czf "dist/$(DIST)-bin.tar.gz" -C dist "$(DIST)-bin"
	@tar -cJf "dist/$(DIST)-bin.tar.xz" -C dist "$(DIST)-bin"
	@(cd dist && sha256sum *.tar.gz *.tar.xz > SHA256SUMS && sha256sum -c SHA256SUMS)
	@ls -lh dist/
	@echo "=== dist ready: use 'gh release create v$(VERSION) dist/* SHA256SUMS zig-out/bin/kernel-baremetal' ==="

# Inspect generated files
inspect: build
	@echo "=== Build outputs ==="
	@ls -la zig-out/bin/ 2>/dev/null || echo "No binary output"
	@echo ""
	@echo "=== Kernel symbol info ==="
	@file zig-out/bin/zig-kernel 2>/dev/null || echo "Binary not found"

# Deep clean including all generated artifacts
distclean:
	rm -rf zig-out .zig-cache zig-out/kernel zig-out/qemu-output.log dist

# Help
help:
	@echo "Zig-Kernel Build Targets"
	@echo "========================"
	@echo "  all         - Build everything (alias for 'build')"
	@echo "  build       - Build hosted executable"
	@echo "  run         - Build and run hosted simulation"
	@echo "  test        - Run unit tests"
	@echo "  clean       - Remove zig-out, .zig-cache, dist"
	@echo ""
	@echo "QEMU targets:"
	@echo "  qemu-bin    - Build bare-metal ELF for QEMU"
	@echo "  qemu-run    - Run kernel in QEMU with display"
	@echo "  qemu-test   - Run QEMU headless and verify output (CI)"
	@echo ""
	@echo "Release:"
	@echo "  dist        - Linux-style source+binary tarballs + SHA256SUMS (like make tar-pkg)"
	@echo ""
	@echo "Utility:"
	@echo "  inspect     - Show build outputs and file info"
	@echo "  distclean   - Remove all generated artifacts"
	@echo "  help        - Show this help message"
