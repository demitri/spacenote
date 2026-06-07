# SpaceNote — bundle assembly (PLAN.md §5). No Xcode project; SwiftPM + this.
APP      = dist/SpaceNote.app
BINARY   = .build/release/SpaceNote
INSTALL_DIR = $(HOME)/Applications

.PHONY: app run install clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
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
