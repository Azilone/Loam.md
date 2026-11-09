# Every target runs Swift through scripts/swift.sh: natively if installed, else in a container.
# On a Mac, `build` and `test` also cover the app in App/ (macOS 26, native Swift only).
# Executables live in their own packages (CLI/, App/Executable/) so they link the runtime libraries dynamically.
.PHONY: dist build test test-fast perf perf-ui release app installer run dev ps stop-all test-vault example-plugin plugin-api clean

MACOS := $(filter Darwin,$(shell uname))
# Builds and tests from every worktree take turns on one machine-wide lock (scripts/build-lock.sh).
LOCK := scripts/build-lock.sh

build:
	./$(LOCK) ./scripts/swift.sh build
	./$(LOCK) ./scripts/swift.sh build --package-path CLI
ifdef MACOS
	cd App && ../$(LOCK) swift build
	cd App && ../$(LOCK) swift build --package-path Executable
endif

test:
	./$(LOCK) ./scripts/swift.sh test
ifdef MACOS
	cd App && ../$(LOCK) swift test
	./$(LOCK) ./scripts/check-plugin-api.sh
endif

# Records the plugin SDK's API as the new baseline, after bumping PluginSDKVersion.current (docs/PLUGIN-LOADING.md)
plugin-api:
	./scripts/check-plugin-api.sh --update

# Only the tests the working tree's changes reach (BASE=ref to compare with another commit); `make test` before done
test-fast:
	./scripts/test-changed.sh $(BASE)

# Times vault-wide work on a big generated Obsidian-like vault (2 GB, 20,000 notes; docs/PERF.md).
# PERF_VAULT=dir to use another one; PERF_ARGS="--runs 10 --no-budget" to pass options.
PERF_VAULT ?= ~/LoamPerfVault
perf:
	@[ -d $(PERF_VAULT) ] || python3 scripts/make-perf-vault.py $(PERF_VAULT)
	./scripts/swift.sh build -c release --product LoamBench
	.build/release/LoamBench $(PERF_VAULT) $(PERF_ARGS)

# Guards what a person feels in the app (pages, sidebars, tabs, Quick Open, the gallery, scrolling) on a release agent
# instance against budgets (docs/PERF.md). PERF_UI_ARGS="--template ~/LoamTest-RealVault --scenario tab --json F".
perf-ui:
	python3 scripts/perf-ui.py $(PERF_UI_ARGS)

# The `loam` command line, optimised, at CLI/.build/release/loam with its runtime library next to it
release:
	./scripts/build-cli.sh

# A release others can open: Developer ID, hardened runtime, notarized, at dist/ (scripts/notarize.sh says what it needs)
dist:
	./scripts/notarize.sh

# The macOS app, at App/build/Loam.app
app:
	./scripts/build-app.sh

# The native macOS installer wizard, at Installer/build/Loam Installer.app, with the app inside it as the payload.
# A zip and a dmg land in Installer/build/dist/.
installer:
	./scripts/build-installer.sh release

# Builds the app and opens it on a vault: make run VAULT=~/TestVault (a missing vault becomes the demo vault)
# With INSTANCE=name it starts an isolated instance an agent can drive without the screen (own bundle id, preferences,
# vault copy and control socket; docs/AGENT-TESTING.md): make run INSTANCE=foo [VAULT=dir]
VAULT ?= ~/TestVault
run:
ifdef INSTANCE
	./scripts/agent-run.sh "$(INSTANCE)" $(if $(filter command line,$(origin VAULT)),--vault "$(VAULT)")
else
	$(MAKE) app
	@[ -d $(VAULT) ] || ./scripts/make-test-vault.sh $(VAULT)
	open "App/build/Loam.app" --args --vault $(VAULT)
endif

# The fast loop while coding: an incremental debug build, opened on a vault.
# Seconds after a small edit instead of minutes; `make run` for the real release build. make dev VAULT=dir
dev:
	./scripts/dev-refresh.sh || { [ $$? -eq 3 ] && ./scripts/build-app.sh debug; }
	-pkill -f "App/build/Loam.app/Contents/MacOS/Loam"
	@[ -d $(VAULT) ] || ./scripts/make-test-vault.sh $(VAULT)
	open "App/build/Loam.app" --args --vault $(VAULT)

# Every development Loam running and every build in progress, with its worktree and branch
ps:
	@./scripts/loam-ps

# Quits every development Loam (agent instances, dev apps); the installed one stays
stop-all:
	@./scripts/loam-ps --stop all

# A demo vault to try the app on: make test-vault [VAULT=~/TestVault]. Refuses iCloud and non-empty folders.
test-vault:
	./scripts/make-test-vault.sh $(VAULT)

# Builds the example third-party plugin into a vault: make example-plugin VAULT=/tmp/PluginVault
example-plugin:
	./scripts/build-example-plugin.sh $(VAULT)

clean:
	rm -rf .build CLI/.build App/.build App/Executable/.build App/build Examples/HelloPlugin/.build
