.PHONY: build test test-updater run package icon setup-signing release
build:
	bash scripts/build.sh
test:
	bash scripts/test.sh
test-updater:
	bash scripts/test-updater.sh
run: build
	open "build/Dell PBP.app"

package:
	bash scripts/package.sh

icon:
	bash scripts/generate-icon.sh

setup-signing:
	bash scripts/setup-signing.sh

# Example: make release VERSION=1.0.1
release:
	@test -n "$(VERSION)" || { echo 'Usage: make release VERSION=1.0.1'; exit 1; }
	bash scripts/release.sh "$(VERSION)"
