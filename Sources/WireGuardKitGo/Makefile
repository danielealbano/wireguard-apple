# SPDX-License-Identifier: MIT
#
# Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.

# These are generally passed to us by xcode, but we set working defaults for standalone compilation too.
ARCHS ?= x86_64 arm64
PLATFORM_NAME ?= macosx
SDKROOT ?= $(shell xcrun --sdk $(PLATFORM_NAME) --show-sdk-path)
CONFIGURATION_BUILD_DIR ?= $(CURDIR)/out
CONFIGURATION_TEMP_DIR ?= $(CURDIR)/.tmp

export CC ?= clang
LIPO ?= lipo
DESTDIR ?= $(CONFIGURATION_BUILD_DIR)
BUILDDIR ?= $(CONFIGURATION_TEMP_DIR)/wireguard-go-bridge

CFLAGS_PREFIX := $(if $(DEPLOYMENT_TARGET_CLANG_FLAG_NAME),-$(DEPLOYMENT_TARGET_CLANG_FLAG_NAME)=$($(DEPLOYMENT_TARGET_CLANG_ENV_NAME)),) -isysroot $(SDKROOT) -arch
GOARCH_arm64 := arm64
GOARCH_x86_64 := amd64
GOOS_macosx := darwin
GOOS_iphoneos := ios

# Pinned Go toolchain: downloaded (SHA256-verified), then patched with the boottime diff.
# The system Go is NOT used for artifact builds — Go's automatic toolchain switching would
# silently bypass the patched GOROOT, producing binaries whose timers stop across device sleep.
GO_VERSION := 1.26.5
GO_HOST_ARCH_arm64 := arm64
GO_HOST_ARCH_x86_64 := amd64
GO_PLATFORM := darwin-$(GO_HOST_ARCH_$(shell uname -m))
GO_TARBALL := go$(GO_VERSION).$(GO_PLATFORM).tar.gz
GO_HASH_darwin-amd64 := 6231d8d3b8f5552ec6cbf6d685bdd5482e1e703214b120e89b3bf0d7bf1ef725
GO_HASH_darwin-arm64 := efb87ff28af9a188d0536ef5d42e63dd52ba8263cd7344a993cc48dd11dedb6a
GO_HASH := $(GO_HASH_$(GO_PLATFORM))
# The tarball cache survives `clean` so a clean rebuild does not re-download the toolchain;
# the SHA256 is verified at download time and the extracted GOROOT is rebuilt from it as needed.
GO_CACHE_DIR := $(CURDIR)/.cache

export GOROOT := $(BUILDDIR)/goroot
export GOTOOLCHAIN := local
export PATH := $(GOROOT)/bin:$(PATH):/usr/local/bin:/opt/homebrew/bin

build: $(DESTDIR)/libwg-go.a
version-header: $(DESTDIR)/wireguard-go-version.h

$(GO_CACHE_DIR)/$(GO_TARBALL):
	[ -n "$(GO_HASH)" ]
	mkdir -p "$(GO_CACHE_DIR)"
	curl -fLo "$@.tmp" "https://go.dev/dl/$(GO_TARBALL)"
	echo "$(GO_HASH)  $@.tmp" | shasum -a 256 -c
	mv "$@.tmp" "$@"

$(GOROOT)/.prepared: $(GO_CACHE_DIR)/$(GO_TARBALL)
	rm -rf "$(GOROOT)"
	mkdir -p "$(GOROOT)"
	tar -C "$(GOROOT)" --strip-components=1 -xzf "$(GO_CACHE_DIR)/$(GO_TARBALL)"
	cat goruntime-*.diff | patch -p1 -f -N -r- -d "$(GOROOT)"
	touch "$@"

define libwg-go-a
$(BUILDDIR)/libwg-go-$(1).a: export CGO_ENABLED := 1
$(BUILDDIR)/libwg-go-$(1).a: export CGO_CFLAGS := $(CFLAGS_PREFIX) $(ARCH)
$(BUILDDIR)/libwg-go-$(1).a: export CGO_LDFLAGS := $(CFLAGS_PREFIX) $(ARCH)
$(BUILDDIR)/libwg-go-$(1).a: export GOOS := $(GOOS_$(PLATFORM_NAME))
$(BUILDDIR)/libwg-go-$(1).a: export GOARCH := $(GOARCH_$(1))
$(BUILDDIR)/libwg-go-$(1).a: $(GOROOT)/.prepared go.mod
	go build -ldflags=-w -trimpath -v -o "$(BUILDDIR)/libwg-go-$(1).a" -buildmode c-archive
	rm -f "$(BUILDDIR)/libwg-go-$(1).h"
endef
$(foreach ARCH,$(ARCHS),$(eval $(call libwg-go-a,$(ARCH))))

$(DESTDIR)/wireguard-go-version.h: go.mod
	 sed -E -n 's/.*danielealbano\/wireguard-go +v([0-9][0-9.]*).*/#define WIREGUARD_GO_VERSION "\1"/p' "$<" > "$@.tmp"
	 [ -s "$@.tmp" ]
	 mv "$@.tmp" "$@"

$(DESTDIR)/libwg-go.a: $(foreach ARCH,$(ARCHS),$(BUILDDIR)/libwg-go-$(ARCH).a)
	@mkdir -vp "$(DESTDIR)"
	$(LIPO) -create -output "$@" $^

clean:
	rm -rf "$(BUILDDIR)" "$(DESTDIR)/libwg-go.a" "$(DESTDIR)/wireguard-go-version.h"

install: build

.PHONY: clean build version-header install
