# Vendoring chores for the bundled minimidio.h.
#
# This Makefile does NOT build the project — rebar3 owns that (`rebar3 compile`,
# `rebar3 check`). It only wraps the deterministic vendoring of the upstream
# single-header library. See scripts/vendor-minimidio.sh and the README section
# "Updating the vendored minimidio".

SCRIPT := scripts/vendor-minimidio.sh

.PHONY: vendor-minimidio minimidio-verify

## vendor-minimidio SHA=<commit> | REF=<branch|tag> [NO_COMMIT=1]
##   Pull minimidio.h + LICENSE at a revision, update the lock, and make the two
##   attributed commits. NO_COMMIT=1 writes files and prints the commit commands.
vendor-minimidio:
	@if [ -n "$(SHA)" ] && [ -n "$(REF)" ]; then \
	    echo "set only one of SHA= or REF=" >&2; exit 2; fi; \
	ref="$(SHA)$(REF)"; \
	if [ -z "$$ref" ]; then \
	    echo "usage: make vendor-minimidio SHA=<commit> | REF=<branch|tag> [NO_COMMIT=1]" >&2; \
	    exit 2; fi; \
	$(SCRIPT) "$$ref" $(if $(NO_COMMIT),--no-commit)

## minimidio-verify
##   Fail if the in-tree c_src/minimidio.h has drifted from c_src/minimidio.lock.
##   Offline and cheap — suitable as a CI drift gate.
minimidio-verify:
	@$(SCRIPT) --verify
