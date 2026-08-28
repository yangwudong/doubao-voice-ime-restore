# DoubaoVoiceRestore — development tasks.
# Run `make` with no arguments for the list.

BINARY      := DoubaoVoiceRestore
VERSION     := $(shell sed -n 's/^let programVersion = "\(.*\)"/\1/p' Sources/$(BINARY)/main.swift)
RELEASE_BIN := .build/release/$(BINARY)
FAT_BIN     := .build/apple/Products/Release/$(BINARY)
DIST_DIR    := dist
STAGE_DIR   := $(DIST_DIR)/doubao-voice-ime-restore
ARCHIVE     := $(DIST_DIR)/doubao-voice-ime-restore-macos-universal.zip

.DEFAULT_GOAL := help
.PHONY: help build universal run install uninstall fmt lint package clean

help: ## Show the available targets
	@printf 'DoubaoVoiceRestore %s\n\n' '$(VERSION)'
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build a release binary for this Mac
	swift build -c release

universal: ## Build a universal (arm64 + x86_64) release binary
	swift build -c release --arch arm64 --arch x86_64
	@lipo -info $(FAT_BIN)

run: ## Build and run in the foreground (^C to stop)
	swift run -c release $(BINARY)

install: ## Build and install the LaunchAgent for the current user
	@bash scripts/install.sh

uninstall: ## Stop and remove the LaunchAgent
	@bash scripts/uninstall.sh

fmt: ## Format the Swift sources in place
	swift format --in-place --recursive Sources

lint: ## Check formatting without writing changes
	swift format lint --strict --recursive Sources

package: universal ## Assemble the release archive in dist/
	rm -rf $(STAGE_DIR) $(ARCHIVE)
	mkdir -p $(STAGE_DIR)
	cp $(FAT_BIN) $(STAGE_DIR)/$(BINARY)
	cp scripts/install.sh scripts/uninstall.sh $(STAGE_DIR)/
	cp README.md README.en.md LICENSE $(STAGE_DIR)/
	mkdir -p $(STAGE_DIR)/docs
	cp -R docs/images $(STAGE_DIR)/docs/
	chmod +x $(STAGE_DIR)/$(BINARY) $(STAGE_DIR)/install.sh $(STAGE_DIR)/uninstall.sh
	codesign --force --sign - --timestamp=none $(STAGE_DIR)/$(BINARY)
	cd $(DIST_DIR) && ditto -c -k --norsrc --noextattr --keepParent \
		$(notdir $(STAGE_DIR)) $(notdir $(ARCHIVE))
	@printf '\n==> %s\n' '$(ARCHIVE)'

clean: ## Remove build and packaging output
	swift package clean
	rm -rf $(DIST_DIR) .build
