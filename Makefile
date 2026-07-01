# SpaceNote — bundle assembly (PLAN.md §5). No Xcode project; SwiftPM + this.
APP      = dist/SpaceNote.app
BINARY   = .build/release/SpaceNote
INSTALL_DIR = $(HOME)/Applications

.PHONY: app run install icon clean

# Regenerate Resources/AppIcon.icns from tools/makeicon.swift (CoreGraphics, no
# external tooling). Renders each iconset size directly, then packs with iconutil.
icon:
	rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	swift tools/makeicon.swift build/AppIcon.iconset/icon_16x16.png      16
	swift tools/makeicon.swift build/AppIcon.iconset/icon_16x16@2x.png   32
	swift tools/makeicon.swift build/AppIcon.iconset/icon_32x32.png      32
	swift tools/makeicon.swift build/AppIcon.iconset/icon_32x32@2x.png   64
	swift tools/makeicon.swift build/AppIcon.iconset/icon_128x128.png   128
	swift tools/makeicon.swift build/AppIcon.iconset/icon_128x128@2x.png 256
	swift tools/makeicon.swift build/AppIcon.iconset/icon_256x256.png   256
	swift tools/makeicon.swift build/AppIcon.iconset/icon_256x256@2x.png 512
	swift tools/makeicon.swift build/AppIcon.iconset/icon_512x512.png   512
	swift tools/makeicon.swift build/AppIcon.iconset/icon_512x512@2x.png 1024
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
	rm -rf build/AppIcon.iconset
	@echo "Built Resources/AppIcon.icns"

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp $(BINARY) $(APP)/Contents/MacOS/SpaceNote
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

# Stable location matters: SMAppService login items key off the bundle's
# identity+path, so run the installed copy day-to-day.
install: app
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/SpaceNote.app
	ditto $(APP) $(INSTALL_DIR)/SpaceNote.app
	@echo "Installed to $(INSTALL_DIR)/SpaceNote.app"

clean:
	rm -rf dist .build
