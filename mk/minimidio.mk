# ============================================================================
# mk/minimidio.mk — the vendored-C side of midiio
#
# Included by ./Makefile. Wraps the deterministic vendoring of the upstream
# single-header library minimidio.h (download / pin / verify, with provenance).
# This does NOT build the project — rebar3 + pc own that (see mk/erlang.mk).
# See scripts/vendor-minimidio.sh and the README "Updating the vendored
# minimidio" section.
#
# Target names `vendor-minimidio` and `minimidio-verify` are stable: the CI
# drift gate (.github/workflows/vendor-check.yml) and the README depend on them.
# ============================================================================

SCRIPT := scripts/vendor-minimidio.sh

.PHONY: help-minimidio
help-minimidio:
	@printf '$(GREEN)Vendored C (minimidio):$(RESET)\n'
	@printf '  $(YELLOW)make vendor-minimidio SHA=<commit>$(RESET)   - Pin/bump minimidio.h to a commit\n'
	@printf '  $(YELLOW)make vendor-minimidio REF=<branch|tag>$(RESET) - Pin/bump to a named ref\n'
	@printf '  $(DIM)      (add NO_COMMIT=1 to write files + print the commit commands)$(RESET)\n'
	@printf '  $(YELLOW)make minimidio-verify$(RESET)               - Fail if the header drifted from the lock\n'
	@printf '  $(YELLOW)make minimidio-info$(RESET)                 - Show the current pin (lock contents)\n'
	@printf '\n'

# --- Vendor (pin / bump / roll back) ----------------------------------------
.PHONY: vendor-minimidio
vendor-minimidio:
	@if [ -n "$(SHA)" ] && [ -n "$(REF)" ]; then \
	    printf '$(RED)✗ set only one of SHA= or REF=$(RESET)\n' >&2; exit 2; fi; \
	ref="$(SHA)$(REF)"; \
	if [ -z "$$ref" ]; then \
	    printf '$(RED)✗ usage: make vendor-minimidio SHA=<commit> | REF=<branch|tag> [NO_COMMIT=1]$(RESET)\n' >&2; \
	    exit 2; fi; \
	printf '$(BLUE)Vendoring minimidio.h @ %s...$(RESET)\n' "$$ref"; \
	$(SCRIPT) "$$ref" $(if $(NO_COMMIT),--no-commit) \
	    && printf '$(GREEN)✓ Vendoring complete$(RESET)\n'

# --- Verify (offline drift gate) --------------------------------------------
.PHONY: minimidio-verify
minimidio-verify:
	@printf '$(BLUE)Verifying vendored minimidio.h against the lock...$(RESET)\n'
	@$(SCRIPT) --verify \
	    && printf '$(GREEN)✓ minimidio.h matches the lock$(RESET)\n' \
	    || { printf '$(RED)✗ minimidio.h has drifted from the lock$(RESET)\n'; exit 1; }

# --- Info (show the current pin) --------------------------------------------
.PHONY: minimidio-info
minimidio-info:
	@if [ ! -f c_src/minimidio.lock ]; then \
	    printf '$(YELLOW)→ no c_src/minimidio.lock (run make vendor-minimidio first)$(RESET)\n'; \
	    exit 0; fi
	@printf '$(CYAN)• Vendored minimidio pin:$(RESET)\n'
	@sed -n 's/^\([a-z0-9_]*\):[[:space:]]*\(.*\)/  \1: \2/p' c_src/minimidio.lock
