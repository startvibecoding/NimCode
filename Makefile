NIM := $(shell which nim 2>/dev/null || echo $(HOME)/.nimble/bin/nim)
BIN = bin/nimcode
SRC = src/nimcode.nim
TESTS = tests/test_tui.nim tests/test_statusbar.nim tests/test_stream.nim tests/test_input.nim

.PHONY: all build release release-binary clean run test test-tui test-statusbar test-stream test-input package-deb package-npm cross-compile help

all: build

build:
	$(NIM) c -d:ssl -o:$(BIN) $(SRC)

release-binary:
	$(NIM) c -d:ssl -d:release -o:$(BIN) $(SRC)

clean:
	rm -f $(BIN)
	rm -f tests/test_tui tests/test_statusbar tests/test_stream tests/test_input

run: build
	./$(BIN)

test: test-tui test-statusbar test-stream test-input
	@echo "All tests passed!"

test-tui:
	@echo "Running TUI tests..."
	$(NIM) c -r -d:ssl tests/test_tui.nim

test-statusbar:
	@echo "Running Status Bar tests..."
	$(NIM) c -r -d:ssl tests/test_statusbar.nim

test-stream:
	@echo "Running Stream tests..."
	$(NIM) c -r -d:ssl tests/test_stream.nim

test-input:
	@echo "Running Input tests..."
	$(NIM) c -r -d:ssl tests/test_input.nim

package-deb:
	@echo "Building Debian package..."
	@./scripts/build-deb.sh

package-npm:
	@echo "Building npm package..."
	@./scripts/npm-publish.sh

cross-compile:
	@echo "Building cross-platform binaries..."
	@./scripts/build-cross-platform.sh

release:
	@echo "Building full release artifacts..."
	@./scripts/release-all.sh

help:
	@echo "Targets:"
	@echo "  build           - Debug build (default)"
	@echo "  release         - Build full release artifacts (.deb, npm, cross-platform)"
	@echo "  cross-compile   - Build binaries for all supported platforms"
	@echo "  package-deb     - Build Debian package for host architecture"
	@echo "  package-npm     - Build npm package (no publish)"
	@echo "  clean           - Remove binary and test executables"
	@echo "  run             - Build and run"
	@echo "  test            - Run all unit tests"
	@echo "  test-tui        - Run TUI module tests"
	@echo "  test-statusbar  - Run Status Bar tests"
	@echo "  test-stream     - Run Stream callback tests"
	@echo "  test-input      - Run Input handling tests"
