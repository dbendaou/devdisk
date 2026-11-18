SWIFT ?= swift
APP := dist/DevDisk.app
CONFIG := release

.PHONY: test build app clean

test:
	$(SWIFT) test

build:
	$(SWIFT) build

# Ad-hoc signed app bundle. Requires macOS with Swift Command Line Tools.
# The binary is arm64 (Apple Silicon). Info.plist sets the minimum system
# version to macOS 26.
app:
	@if [ "$$(uname)" != "Darwin" ]; then \
		echo "error: DevDisk.app can only be built on macOS"; \
		exit 1; \
	fi
	@set -eu; \
	bin="$$($(SWIFT) build -c $(CONFIG) --product DevDisk --arch arm64 --show-bin-path)"; \
	rm -rf "$(APP)"; \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"; \
	cp "$$bin/DevDisk" "$(APP)/Contents/MacOS/DevDisk"; \
	cp App/Info.plist "$(APP)/Contents/Info.plist"; \
	chmod +x "$(APP)/Contents/MacOS/DevDisk"; \
	codesign --force --deep -s - "$(APP)"; \
	echo "Built $(APP)"

clean:
	rm -rf .build dist
