# ============================================================================
# mk/erlang.mk — the BEAM side of midiio (rebar3)
#
# Included by ./Makefile. Expects the shared variables it defines (colours,
# PROJECT_NAME, REBAR, OTP_VERSION). Do not run this module directly.
#
# `rebar3 compile` also builds the NIF (the `pc` port-compiler plugin turns
# c_src/midiio_nif.c into priv/midiio_nif.so), so there is no separate C build
# target here — the native object is a product of compile.
#
# Profile note: the `proper` provider comes from the rebar3_proper plugin, which
# rebar.config scopes to the `test` profile. So test/coverage/check run under
# `as test`; bare `rebar3 check` would fail with "Command proper not found".
# ============================================================================

.PHONY: help-erlang
help-erlang:
	@printf '$(GREEN)BEAM (rebar3):$(RESET)\n'
	@printf '  $(YELLOW)make compile$(RESET)         - Compile the app + NIF\n'
	@printf '  $(YELLOW)make eunit$(RESET)           - Run eunit\n'
	@printf '  $(YELLOW)make proper$(RESET)          - Run PropEr property tests\n'
	@printf '  $(YELLOW)make xref$(RESET)            - Run xref\n'
	@printf '  $(YELLOW)make dialyzer$(RESET)        - Run dialyzer\n'
	@printf '  $(YELLOW)make coverage$(RESET)        - Coverage (proper + cover report)\n'
	@printf '  $(YELLOW)make docs$(RESET)            - Generate ex_doc docs (if configured)\n'
	@printf '  $(YELLOW)make format$(RESET)          - Format sources (if a formatter is configured)\n'
	@printf '  $(YELLOW)make shell$(RESET)           - Start a rebar3 shell with the app loaded\n'
	@printf '  $(YELLOW)make asan$(RESET)            - Build + run the C ASan lifecycle harness\n'
	@printf '  $(YELLOW)make distclean$(RESET)       - Deep clean (remove _build)\n'
	@printf '  $(YELLOW)make publish$(RESET)         - Publish to Hex (confirmation-gated)\n'
	@printf '\n'

# --- Building ---------------------------------------------------------------
.PHONY: compile
compile:
	@printf '$(BLUE)Compiling %s (app + NIF)...$(RESET)\n' "$(PROJECT_NAME)"
	@$(REBAR) compile
	@printf '$(GREEN)✓ Compiled$(RESET)\n'

# --- Testing ----------------------------------------------------------------
.PHONY: eunit proper
eunit:
	@printf '$(BLUE)Running eunit...$(RESET)\n'
	@$(REBAR) as test eunit
	@printf '$(GREEN)✓ eunit passed$(RESET)\n'

proper:
	@printf '$(BLUE)Running PropEr property tests...$(RESET)\n'
	@$(REBAR) as test proper
	@printf '$(GREEN)✓ PropEr passed$(RESET)\n'

# --- Quality / linting ------------------------------------------------------
.PHONY: xref dialyzer
xref:
	@printf '$(BLUE)Running xref...$(RESET)\n'
	@$(REBAR) xref
	@printf '$(GREEN)✓ xref passed$(RESET)\n'

dialyzer:
	@printf '$(BLUE)Running dialyzer...$(RESET)\n'
	@$(REBAR) dialyzer
	@printf '$(GREEN)✓ dialyzer passed$(RESET)\n'

# --- Coverage ---------------------------------------------------------------
.PHONY: coverage
coverage:
	@printf '$(BLUE)Generating coverage (proper + cover)...$(RESET)\n'
	@$(REBAR) as test coverage
	@printf '$(GREEN)✓ Coverage generated$(RESET)\n'

# --- Documentation ----------------------------------------------------------
.PHONY: docs
docs:
	@printf '$(BLUE)Generating docs...$(RESET)\n'
	@$(REBAR) ex_doc 2>/dev/null \
	    && printf '$(GREEN)✓ Docs generated$(RESET)\n' \
	    || printf '$(YELLOW)→ ex_doc not configured; skipping$(RESET)\n'

# --- Formatting -------------------------------------------------------------
.PHONY: format
format:
	@printf '$(BLUE)Formatting sources...$(RESET)\n'
	@$(REBAR) fmt 2>/dev/null \
	    && printf '$(GREEN)✓ Formatted$(RESET)\n' \
	    || printf '$(YELLOW)→ no formatter configured (e.g. erlfmt); skipping$(RESET)\n'

# --- REPL -------------------------------------------------------------------
.PHONY: shell
shell:
	@$(REBAR) shell

# --- C sanitizer harness ----------------------------------------------------
# The standalone ASan harness exercises the minimidio context lifecycle the NIF
# drives (no BEAM needed). LeakSanitizer is Linux-only; on macOS this covers
# use-after-free / double-free / overflow.
.PHONY: asan
asan:
	@printf '$(BLUE)Building + running the C ASan harness...$(RESET)\n'
	@cc -fsanitize=address -g -std=c11 -Wall -Wextra -Wno-unused-function \
	    c_src/test/midiio_asan.c -o /tmp/midiio_asan \
	    $$(uname -s | grep -qi darwin && echo '-framework CoreMIDI' || echo '-lasound -lpthread') \
	    && /tmp/midiio_asan \
	    && printf '$(GREEN)✓ ASan clean$(RESET)\n'

# --- Cleaning ---------------------------------------------------------------
.PHONY: clean-erlang distclean
clean-erlang:
	@printf '$(BLUE)Cleaning build artifacts...$(RESET)\n'
	@$(REBAR) clean
	@rm -f erl_crash.dump c_src/*.o c_src/*.d priv/*.so
	@printf '$(GREEN)✓ Clean complete$(RESET)\n'

distclean: clean-erlang
	@printf '$(BLUE)Deep cleaning (_build)...$(RESET)\n'
	@rm -rf _build
	@printf '$(GREEN)✓ Deep clean complete (_build removed)$(RESET)\n'

# --- Publishing -------------------------------------------------------------
# Confirmation-gated Hex publish. The `publish` alias (rebar.config) runs
# compile + `hex publish package`; Hex auth + a clean tree are assumed.
.PHONY: publish
publish:
	@printf '\n'
	@printf '$(CYAN)╔════════════════════════════════════════════════════════════╗$(RESET)\n'
	@printf '$(CYAN)║$(RESET)  $(BLUE)%-58s$(RESET)$(CYAN)║$(RESET)\n' "Publish $(PROJECT_NAME) v$(APP_VERSION) to Hex"
	@printf '$(CYAN)╚════════════════════════════════════════════════════════════╝$(RESET)\n'
	@printf '\n'
	@printf '$(YELLOW)⚠ This publishes %s v%s to hex.pm (public, ~irreversible).$(RESET)\n' "$(PROJECT_NAME)" "$(APP_VERSION)"
	@printf '$(YELLOW)⚠ Ensure the version is bumped and the tree is clean + tested.$(RESET)\n'
	@printf '\n'
	@printf 'Continue? [y/N] '
	@read REPLY; case "$$REPLY" in [Yy]*) ;; *) printf '$(RED)✗ Aborted$(RESET)\n'; exit 1 ;; esac
	@printf '$(BLUE)Publishing to Hex...$(RESET)\n'
	@$(REBAR) publish
	@printf '$(GREEN)✓ Published %s v%s$(RESET)\n' "$(PROJECT_NAME)" "$(APP_VERSION)"
