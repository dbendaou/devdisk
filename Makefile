SWIFT ?= swift
APP := dist/DevDisk.app
CONFIG := release

.PHONY: test build app clean

test:
	$(SWIFT) test
	@if [ "$$(uname)" = "Darwin" ]; then \
		$(SWIFT) build --product DevDisk; \
	fi

build:
	$(SWIFT) build

# Ad-hoc signed app bundle. macOS only; the host is Apple Silicon, so the
# default release path is .build/release/DevDisk. Do not pass --arch: with
# Xcode installed that switches SwiftPM to the Xcode build system. Do not
# use --show-bin-path alone: it prints a path and does not build.
app:
	@if [ "$$(uname)" != "Darwin" ]; then \
		echo "error: DevDisk.app can only be built on macOS"; \
		exit 1; \
	fi
	$(SWIFT) build -c $(CONFIG) --product DevDisk
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp .build/$(CONFIG)/DevDisk "$(APP)/Contents/MacOS/DevDisk"
	cp App/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	chmod +x "$(APP)/Contents/MacOS/DevDisk"
	codesign --force --deep -s - "$(APP)"
	@echo "Built $(APP)"

clean:
	rm -rf .build dist
