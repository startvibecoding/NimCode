NIM := $(shell which nim 2>/dev/null || echo $(HOME)/.nimble/bin/nim)
BIN = bin/nimcode
SRC = src/nimcode.nim

.PHONY: all build release clean run help

all: build

build:
	$(NIM) c -d:ssl -o:$(BIN) $(SRC)

release:
	$(NIM) c -d:ssl -d:release -o:$(BIN) $(SRC)

clean:
	rm -f $(BIN)

run: build
	./$(BIN)

help:
	@echo "Targets:"
	@echo "  build    - Debug build (default)"
	@echo "  release  - Release build with optimizations"
	@echo "  clean    - Remove binary"
	@echo "  run      - Build and run"
