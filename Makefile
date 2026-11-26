EMACS ?= emacs
DEPS_DIR ?= .deps
DEPS ?= $(DEPS_DIR)/agent-shell $(DEPS_DIR)/acp $(DEPS_DIR)/shell-maker $(DEPS_DIR)/vui
# Optional: its tests use it when it's there (a diagram's source coloured).
TEST_DEPS ?= $(DEPS_DIR)/mermaid-mode
LOAD_PATH = -L . $(addprefix -L ,$(DEPS))

ELS = $(filter-out agent-ui-autoloads.el,$(sort $(wildcard agent-ui*.el)))
TEST_FILES = tests/agent-ui-test-helper.el $(sort $(wildcard tests/*-tests.el))

BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' $(LOAD_PATH)

.PHONY: all deps media-deps compile lint package-lint checkdoc melpazoid test media clean

all: compile lint test

# The dependencies, cloned once into .deps/ (or point DEPS at your own).
deps:
	@mkdir -p $(DEPS_DIR)
	@test -d $(DEPS_DIR)/agent-shell || git clone --depth 1 https://github.com/xenodium/agent-shell $(DEPS_DIR)/agent-shell
	@test -d $(DEPS_DIR)/acp || git clone --depth 1 https://github.com/xenodium/acp.el $(DEPS_DIR)/acp
	@test -d $(DEPS_DIR)/shell-maker || git clone --depth 1 https://github.com/xenodium/shell-maker $(DEPS_DIR)/shell-maker
	@test -d $(DEPS_DIR)/vui || git clone --depth 1 https://github.com/d12frosted/vui.el $(DEPS_DIR)/vui
	@test -d $(DEPS_DIR)/mermaid-mode || git clone --depth 1 https://github.com/abrochard/mermaid-mode $(DEPS_DIR)/mermaid-mode
	@test -d $(DEPS_DIR)/package-lint || git clone --depth 1 https://github.com/purcell/package-lint $(DEPS_DIR)/package-lint

# The screenshots' theme (scripts/media.sh).
media-deps: deps
	@test -d $(DEPS_DIR)/doom-themes || git clone --depth 1 https://github.com/doomemacs/themes $(DEPS_DIR)/doom-themes

# Every file byte-compiled, a warning an error.
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(ELS)

lint: package-lint checkdoc

package-lint:
	$(BATCH) -L $(DEPS_DIR)/package-lint \
	  --eval "(require 'package)" \
	  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	  --eval "(package-initialize)" \
	  --eval "(unless package-archive-contents (package-refresh-contents))" \
	  --eval "(require 'package-lint)" \
	  --eval "(setq package-lint-main-file \"agent-ui.el\")" \
	  -f package-lint-batch-and-exit $(ELS)

# The checks MELPA's reviewers run on its recipe (needs Docker), as CI does.
RECIPE = (agent-ui :fetcher github :repo "smyrgeorge/agent-ui" :files (:defaults "bin" "skills" "assets"))
melpazoid:
	@test -d $(DEPS_DIR)/melpazoid || git clone --depth 1 https://github.com/riscy/melpazoid $(DEPS_DIR)/melpazoid
	LOCAL_REPO="$(CURDIR)" RECIPE='$(RECIPE)' EXIST_OK=false $(MAKE) -C $(DEPS_DIR)/melpazoid

checkdoc:
	$(BATCH) -l scripts/checkdoc-batch.el $(ELS)

test:
	$(BATCH) -L tests $(addprefix -L ,$(wildcard $(TEST_DEPS))) \
	  --eval '(setq ert-load-file-name "test-results")' \
	  $(addprefix --load ,$(TEST_FILES)) \
	  -f ert-run-tests-batch-and-exit

# The README's screenshots and GIFs, made again (macOS; see scripts/media.sh).
media:
	scripts/media.sh

clean:
	rm -f *.elc tests/*.elc test-results.xml
