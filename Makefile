# SideStore Reflector - binary build (static, musl/aarch64)
#
# Default: static aarch64 cross-compilation (WSL -> Slate 7).
# Override with: make CC=... CFLAGS=...
#
#   make        cross-compile the binary into build/
#   make host   native build, for testing the swap logic on a PC
#   make ipk    build the OpenWrt package into dist/
#   make check  validate everything that goes into the package
#   make clean  remove the binaries

ifeq ($(origin CC),default)
CC := aarch64-linux-gcc
endif

TARGET_ARCH ?= aarch64

CFLAGS   ?= -O2 -Wall -Wextra -std=c11
LDFLAGS  ?= -static

TARGET   := build/sidestore-reflector-arm64
HOSTBIN  := build/sidestore-reflector

all: $(TARGET)

$(TARGET): src/main.c
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ src/main.c $(LDFLAGS)
	@file $@

host:
	@mkdir -p build
	gcc $(CFLAGS) -o $(HOSTBIN) src/main.c
	@file $(HOSTBIN)

# Package and check go through the scripts so there is a single source of truth.
ipk:
	./scripts/build-ipk.sh

check:
	./scripts/validate.sh

clean:
	rm -f $(TARGET) $(HOSTBIN)

.PHONY: all host ipk check clean
