# Build and sign the Xcode macOS app.
#
#   make build    Debug app in build/Build/Products/Debug
#   make release  Release app, host arch only
#   make bundle   signed Release app in build/Build/Products/Release
#   make run      build and open the Debug app
#   make install  notarize and copy the app to /Applications
#   make dist     notarized app packaged as a DMG

PROJECT_NAME   = iamtunnel
BUNDLE_ID      = com.abhishek.iamtunnel
PROJECT        = $(PROJECT_NAME).xcodeproj
SCHEME         = SSMTunnelManager
TEAM_ID       ?= BS489TX7LK
SIGN_IDENTITY ?= Developer ID Application: Abhishek Bhakat (BS489TX7LK)
NOTARY_PROFILE ?= AC_PASSWORD

# Leave empty to keep the asset catalog's icon.
ICON_ICNS     ?=

BUILD_DIR  = build
DIST_DIR   = $(BUILD_DIR)/dist
APP_BUNDLE = $(BUILD_DIR)/Build/Products/Release/$(PROJECT_NAME).app
DEBUG_APP  = $(BUILD_DIR)/Build/Products/Debug/$(PROJECT_NAME).app
DEST       = platform=macOS
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

HOST_ARCH := $(shell uname -m)
ARCH      ?= $(HOST_ARCH)

ifeq ($(ARCH),universal)
ARCHS_VALUE = arm64 x86_64
ONLY_ACTIVE = NO
else
ARCHS_VALUE = $(ARCH)
ONLY_ACTIVE = YES
endif

VERSION   = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || echo "1.0")
DIST_NAME = $(PROJECT_NAME)-$(VERSION)-macOS-$(ARCH)

.PHONY: all build run release release-arm64 release-x86_64 release-universal \
	bundle clean list sign zip notarize dmg dist install uninstall help

all: build

list:
	xcodebuild -list -project "$(PROJECT)"

build:
	xcodebuild build \
	  -project "$(PROJECT)" \
	  -scheme "$(SCHEME)" \
	  -configuration Debug \
	  -destination "$(DEST)" \
	  -derivedDataPath "$(BUILD_DIR)" \
	  ARCHS="$(HOST_ARCH)" \
	  ONLY_ACTIVE_ARCH=YES \
	  DEVELOPMENT_TEAM="$(TEAM_ID)" \
	  CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
	  CODE_SIGN_STYLE=Manual

define EMBED_ICON
	@if [ -n "$(ICON_ICNS)" ]; then \
		cp "$(ICON_ICNS)" "$(1)/Contents/Resources/AppIcon.icns"; \
	fi
endef

run: build
	$(call EMBED_ICON,$(DEBUG_APP))
	@if [ -n "$(ICON_ICNS)" ]; then \
		codesign --force --sign "$(SIGN_IDENTITY)" --options runtime \
			--preserve-metadata=entitlements "$(DEBUG_APP)"; \
	fi
	open "$(DEBUG_APP)"

release:
	xcodebuild build \
	  -project "$(PROJECT)" \
	  -scheme "$(SCHEME)" \
	  -configuration Release \
	  -destination "$(DEST)" \
	  -derivedDataPath "$(BUILD_DIR)" \
	  ARCHS="$(ARCHS_VALUE)" \
	  ONLY_ACTIVE_ARCH=$(ONLY_ACTIVE) \
	  DEVELOPMENT_TEAM="$(TEAM_ID)" \
	  CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
	  CODE_SIGN_STYLE=Manual

release-arm64:
	$(MAKE) release ARCH=arm64

release-x86_64:
	$(MAKE) release ARCH=x86_64

release-universal:
	$(MAKE) release ARCH=universal

define SIGN_APP
	$(call EMBED_ICON,$(1))
	codesign --force --timestamp --sign "$(SIGN_IDENTITY)" \
		--identifier "$(BUNDLE_ID)" \
		--options runtime \
		"$(1)"
	codesign --verify --deep --strict "$(1)"
endef

sign: release
	$(call SIGN_APP,$(APP_BUNDLE))

bundle: sign
	@echo "built $(APP_BUNDLE)"

define CREATE_ZIP
	@mkdir -p "$(DIST_DIR)"
	ditto -c -k --keepParent "$(1)" "$(DIST_DIR)/$(2).zip"
endef

zip: sign
	$(call CREATE_ZIP,$(APP_BUNDLE),$(DIST_NAME))

notarize: zip
	xcrun notarytool submit "$(DIST_DIR)/$(DIST_NAME).zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	@rm -f "$(DIST_DIR)/$(DIST_NAME).zip"
	$(call CREATE_ZIP,$(APP_BUNDLE),$(DIST_NAME))

define CREATE_DMG
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(DIST_DIR)/$(2).dmg"
	@if command -v create-dmg >/dev/null 2>&1; then \
		create-dmg --volname "$(PROJECT_NAME) $(VERSION)" \
			--window-pos 200 120 --window-size 600 400 --icon-size 100 \
			--app-drop-link 450 185 --icon "$(PROJECT_NAME).app" 150 185 \
			"$(DIST_DIR)/$(2).dmg" "$(1)"; \
	else \
		hdiutil create -srcfolder "$(1)" -volname "$(PROJECT_NAME)" -fs HFS+ \
			-format UDZO -o "$(DIST_DIR)/$(2).dmg"; \
	fi
endef

dmg: notarize
	$(call CREATE_DMG,$(APP_BUNDLE),$(DIST_NAME))

dist: dmg

install: notarize
	@pkill -x "$(PROJECT_NAME)" >/dev/null 2>&1 || true
	@rm -rf "/Applications/$(PROJECT_NAME).app"
	ditto "$(APP_BUNDLE)" "/Applications/$(PROJECT_NAME).app"
	codesign --verify --deep --strict "/Applications/$(PROJECT_NAME).app"
	@echo "installed /Applications/$(PROJECT_NAME).app"

uninstall:
	rm -rf "/Applications/$(PROJECT_NAME).app"

clean:
	xcodebuild clean -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(BUILD_DIR)"
	rm -rf "$(BUILD_DIR)"

help:
	@echo "make build | run | release | release-arm64 | release-x86_64 | release-universal"
	@echo "make bundle | sign | zip | notarize | dmg | dist | install | uninstall | clean | list"
	@echo "Default release is host arch ($(HOST_ARCH)). Override: make release ARCH=x86_64"
	@echo "Notarization uses keychain profile $(NOTARY_PROFILE); install and dist require it."
