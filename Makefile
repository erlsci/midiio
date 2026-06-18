# ============================================================================
# midiio — top-level build system
#
# midiio has two areas of responsibility, one per included module:
#
#   mk/erlang.mk     — the BEAM side: compile (incl. the NIF via rebar3 + pc),
#                      test, lint, coverage, docs, publish  (rebar3)
#   mk/minimidio.mk  — the vendored C: download/pin/verify the single-header
#                      minimidio.h with provenance            (scripts/…)
#
# The included modules expect the shared variables defined below (colours,
# identity, git). Run everything through this Makefile, not the modules.
#
#   make            # help
#   make build      # compile (BEAM + NIF)
#   make test       # eunit + proper
#   make check      # full local gate: drift-verify + rebar3 as test check
#   make info       # build/tool information
# ============================================================================

# --- ANSI colours (shared) --------------------------------------------------
# A real ESC byte is baked in at parse time via printf, so the codes render
# under any shell's `echo`/`printf` (macOS /bin/sh and Linux dash alike) —
# unlike a literal "\033", whose expansion is shell-dependent.
ESC    := $(shell printf '\033')
BLUE   := $(ESC)[1;34m
GREEN  := $(ESC)[1;32m
YELLOW := $(ESC)[1;33m
RED    := $(ESC)[1;31m
CYAN   := $(ESC)[1;36m
DIM    := $(ESC)[2m
RESET  := $(ESC)[0m

# --- Identity (shared by the included modules) ------------------------------
PROJECT_NAME := midiio
APP_VERSION  := $(shell grep vsn src/$(PROJECT_NAME).app.src 2>/dev/null | cut -d'"' -f2)
GIT_COMMIT   := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH   := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_TIME   := $(shell date -u '+%Y-%m-%dT%H:%M:%SZ')
OTP_VERSION  := $(shell erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo "not installed")
REBAR        := rebar3

.DEFAULT_GOAL := help

# --- Modules ----------------------------------------------------------------
include mk/erlang.mk
include mk/minimidio.mk
include mk/docker.mk

# ============================================================================
# Help
# ============================================================================
.PHONY: help
help: help-general help-erlang help-minimidio help-docker

.PHONY: help-general
help-general:
	@printf '\n'
	@printf '$(CYAN)╔════════════════════════════════════════════════════════════╗$(RESET)\n'
	@printf '$(CYAN)║$(RESET)  $(BLUE)%-58s$(RESET)$(CYAN)║$(RESET)\n' "$(PROJECT_NAME) v$(APP_VERSION) - realtime MIDI I/O for the BEAM (NIF)"
	@printf '$(CYAN)╚════════════════════════════════════════════════════════════╝$(RESET)\n'
	@printf '\n'
	@printf '$(GREEN)General:$(RESET)\n'
	@printf '  $(YELLOW)make build$(RESET)            - Compile the app + NIF (rebar3 compile)\n'
	@printf '  $(YELLOW)make test$(RESET)             - eunit + PropEr\n'
	@printf '  $(YELLOW)make lint$(RESET)             - xref + dialyzer\n'
	@printf '  $(YELLOW)make check$(RESET)            - Full gate: drift-verify + rebar3 as test check\n'
	@printf '  $(YELLOW)make ci$(RESET)               - Alias for check\n'
	@printf '  $(YELLOW)make clean$(RESET)            - Clean build artifacts\n'
	@printf '  $(YELLOW)make info$(RESET)             - Show build information\n'
	@printf '  $(YELLOW)make check-tools$(RESET)      - Verify required tools\n'
	@printf '\n'

# ============================================================================
# Aggregate targets
# ============================================================================
.PHONY: build test lint check ci clean

build: compile
	@printf '$(GREEN)✓ Built %s (BEAM + NIF)$(RESET)\n' "$(PROJECT_NAME)"

test: eunit proper
	@printf '\n$(GREEN)✓ All tests passed (eunit + PropEr)$(RESET)\n\n'

lint: xref dialyzer
	@printf '\n$(GREEN)✓ Lint passed (xref + dialyzer)$(RESET)\n\n'

# Full local gate. Runs the offline drift check first, then rebar3's own
# comprehensive alias under the test profile (the proper plugin is test-scoped).
check: minimidio-verify
	@printf '$(BLUE)Running full check (rebar3 as test check)...$(RESET)\n'
	@$(REBAR) as test check
	@printf '\n$(GREEN)✓ All checks passed$(RESET)\n\n'

ci: check
	@printf '$(GREEN)✓ CI gate passed$(RESET)\n'

clean: clean-erlang
	@printf '$(GREEN)✓ Cleaned$(RESET)\n'

# ============================================================================
# Information
# ============================================================================
.PHONY: info
info:
	@printf '\n'
	@printf '$(CYAN)╔════════════════════════════════════════════════════════════╗$(RESET)\n'
	@printf '$(CYAN)║$(RESET)  $(BLUE)%-58s$(RESET)$(CYAN)║$(RESET)\n' "Build Information"
	@printf '$(CYAN)╚════════════════════════════════════════════════════════════╝$(RESET)\n'
	@printf '\n'
	@printf '$(GREEN)Project:$(RESET)\n'
	@printf '  Name:        %s v%s\n' "$(PROJECT_NAME)" "$(APP_VERSION)"
	@printf '  Build Time:  %s\n' "$(BUILD_TIME)"
	@printf '  Workspace:   %s\n' "$$(pwd)"
	@printf '\n'
	@printf '$(GREEN)Git:$(RESET)\n'
	@printf '  Branch:      %s\n' "$(GIT_BRANCH)"
	@printf '  Commit:      %s\n' "$(GIT_COMMIT)"
	@printf '\n'
	@printf '$(GREEN)Vendored minimidio:$(RESET)\n'
	@if [ -f c_src/minimidio.lock ]; then \
	    printf '  Version:     %s\n' "$$(sed -n 's/^version:[[:space:]]*//p' c_src/minimidio.lock)"; \
	    printf '  Commit:      %s\n' "$$(sed -n 's/^commit:[[:space:]]*//p' c_src/minimidio.lock | cut -c1-12)"; \
	else printf '  $(YELLOW)(no c_src/minimidio.lock)$(RESET)\n'; fi
	@printf '\n'
	@printf '$(GREEN)Tools:$(RESET)\n'
	@printf '  OTP:         %s\n' "$(OTP_VERSION)"
	@printf '  Rebar3:      %s\n' "$$($(REBAR) --version 2>/dev/null || echo 'not found')"
	@printf '  CC:          %s\n' "$$(cc --version 2>/dev/null | head -1 || echo 'not found')"
	@printf '\n'

# ============================================================================
# Tool check
# ============================================================================
.PHONY: check-tools
check-tools:
	@printf '$(BLUE)Checking for required tools...$(RESET)\n'
	@command -v erl    >/dev/null 2>&1 && printf '  $(GREEN)✓ erl found (OTP %s)$(RESET)\n' "$(OTP_VERSION)" || printf '  $(RED)✗ erl not found$(RESET)\n'
	@command -v $(REBAR) >/dev/null 2>&1 && printf '  $(GREEN)✓ rebar3 found$(RESET)\n' || printf '  $(RED)✗ rebar3 not found$(RESET)\n'
	@command -v cc     >/dev/null 2>&1 && printf '  $(GREEN)✓ C compiler found$(RESET)\n' || printf '  $(RED)✗ no C compiler (cc) found$(RESET)\n'
	@command -v curl   >/dev/null 2>&1 && printf '  $(GREEN)✓ curl found$(RESET)\n' || printf '  $(RED)✗ curl not found (needed for vendoring)$(RESET)\n'
	@command -v git    >/dev/null 2>&1 && printf '  $(GREEN)✓ git found$(RESET)\n' || printf '  $(RED)✗ git not found$(RESET)\n'
	@command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
	    && printf '  $(GREEN)✓ sha256 tool found$(RESET)\n' || printf '  $(RED)✗ no sha256sum/shasum$(RESET)\n'
