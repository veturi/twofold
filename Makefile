APP := build/Twofold.app
PREFIX ?= $(HOME)/.local
APP_DIR ?= $(HOME)/Applications

.PHONY: all app start test bench release icon social-card install uninstall clean

all: app

## Build build/Twofold.app (release, native architecture)
app:
	@./scripts/bundle.sh release

## Build and launch. Pass files or folders with ARGS="a b"
start: app
	@TWOFOLD_APP="$(CURDIR)/$(APP)" ./scripts/twofold $(ARGS)

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

## Regenerate the website's link preview image from its icon and hero screenshot
social-card:
	swift scripts/make-social-card.swift docs/assets/social-card.png

## Copy the app to ~/Applications and the twofold command to ~/.local/bin
install: app
	@mkdir -p "$(APP_DIR)" "$(PREFIX)/bin"
	@rm -rf "$(APP_DIR)/Twofold.app"
	@cp -R "$(APP)" "$(APP_DIR)/"
	@sed 's|^DEFAULT_APP=.*|DEFAULT_APP="$(APP_DIR)/Twofold.app"|' scripts/twofold > "$(PREFIX)/bin/twofold"
	@chmod +x "$(PREFIX)/bin/twofold"
	@echo "Installed $(APP_DIR)/Twofold.app and $(PREFIX)/bin/twofold"

uninstall:
	rm -rf "$(APP_DIR)/Twofold.app" "$(PREFIX)/bin/twofold"

clean:
	rm -rf .build build
