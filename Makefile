NIM := $(shell which nim 2>/dev/null || echo $(HOME)/.nimble/bin/nim)
BIN = bin/nimcode
SRC = src/nimcode.nim
TESTS = tests/test_tui.nim tests/test_statusbar.nim tests/test_stream.nim tests/test_input.nim

.PHONY: all build release clean run test test-tui test-statusbar test-stream test-input help

all: build

build:
	$(NIM) c -d:ssl -o:$(BIN) $(SRC)

release:
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

help:
	@echo "Targets:"
	@echo "  build         - Debug build (default)"
	@echo "  release       - Release build with optimizations"
	@echo "  clean         - Remove binary and test executables"
	@echo "  run           - Build and run"
	@echo "  test          - Run all unit tests"
	@echo "  test-tui      - Run TUI module tests"
	@echo "  test-statusbar - Run Status Bar tests"
	@echo "  test-stream   - Run Stream callback tests"
	@echo "  test-input    - Run Input handling tests"
