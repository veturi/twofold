APP := build/VisDiff.app
PREFIX ?= $(HOME)/.local
APP_DIR ?= $(HOME)/Applications

.PHONY: all app start test bench release icon install uninstall clean

all: app

## Build build/VisDiff.app (release, native architecture)
app:
	@./scripts/bundle.sh release

## Build and launch. Pass files or folders with ARGS="a b"
start: app
	@VISDIFF_APP="$(CURDIR)/$(APP)" ./scripts/visdiff $(ARGS)

## Run the unit tests
test:
	swift test

## Run the diff benchmark in release mode
bench:
	swift test -c release --filter BenchmarkTests 2>&1 | grep BENCH

## Universal (arm64 + x86_64) release bundle
release:
	@UNIVERSAL=1 ./scripts/bundle.sh release

## Regenerate Resources/AppIcon.icns
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

## Copy the app to ~/Applications and the visdiff command to ~/.local/bin
install: app
	@mkdir -p "$(APP_DIR)" "$(PREFIX)/bin"
	@rm -rf "$(APP_DIR)/VisDiff.app"
	@cp -R "$(APP)" "$(APP_DIR)/"
	@sed 's|^DEFAULT_APP=.*|DEFAULT_APP="$(APP_DIR)/VisDiff.app"|' scripts/visdiff > "$(PREFIX)/bin/visdiff"
	@chmod +x "$(PREFIX)/bin/visdiff"
	@echo "Installed $(APP_DIR)/VisDiff.app and $(PREFIX)/bin/visdiff"

uninstall:
	rm -rf "$(APP_DIR)/VisDiff.app" "$(PREFIX)/bin/visdiff"

clean:
	rm -rf .build build
