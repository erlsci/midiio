# ============================================================================
# mk/docker.mk — local Linux test harness in Docker
#
# Runs the CI `check` + `asan` legs on a real glibc/ALSA Linux image so Linux
# build regressions (e.g. the _GNU_SOURCE ALSA bug) surface locally — before a
# push — instead of only on GitHub. Expects the shared colour vars from the
# top-level Makefile.
#
#   make docker-test    # build the image + run the full Linux gate
#   make docker-clean   # remove the local image
#
# ALSA runtime rows need a kernel sequencer (/dev/snd/seq). Containers share the
# host kernel, so those rows run only when the *Docker host* provides one (a
# Linux host with `sudo modprobe snd-virmidi` loaded). The target passes the
# device through automatically when /dev/snd exists; on macOS/Windows hosts it
# does not, and the rows self-skip — identical to the hosted CI runners.
# ============================================================================

DOCKER       ?= docker
DOCKER_IMAGE ?= midiio-test

# Pass the sequencer through only when the host actually exposes one.
DOCKER_SND   := $(if $(wildcard /dev/snd),--device /dev/snd,)
# AddressSanitizer/LeakSanitizer need ptrace, which the default container
# seccomp/cap profile blocks — grant it so `make asan` runs inside Docker.
DOCKER_ASAN  := --cap-add SYS_PTRACE --security-opt seccomp=unconfined

.PHONY: help-docker
help-docker:
	@printf '$(GREEN)Local Linux harness:$(RESET)\n'
	@printf '  $(YELLOW)make docker-test$(RESET)        - Build image + run the Linux gate in Docker (runtime rows skip on macOS)\n'
	@printf '  $(YELLOW)make docker-clean$(RESET)       - Remove the local $(DOCKER_IMAGE) image\n'
	@printf '  $(YELLOW)make vm-test$(RESET)            - Run the FULL gate in a multipass VM (ALSA runtime rows run)\n'
	@printf '  $(YELLOW)make vm-shell$(RESET)           - Open a shell in the $(VM_NAME) VM\n'
	@printf '  $(YELLOW)make vm-clean$(RESET)           - Delete the $(VM_NAME) VM\n'
	@printf '\n'

.PHONY: docker-test
docker-test:
	@printf '$(BLUE)Building Linux test image ($(DOCKER_IMAGE))...$(RESET)\n'
	@$(DOCKER) build -f Dockerfile.test -t $(DOCKER_IMAGE) .
	@if [ -e /dev/snd ]; then \
	    printf '$(GREEN)→ host /dev/snd present; ALSA runtime rows will run$(RESET)\n'; \
	else \
	    printf '$(YELLOW)→ no host /dev/snd; ALSA runtime rows skip (deferred), as on CI$(RESET)\n'; \
	fi
	@printf '$(BLUE)Running full Linux gate in Docker...$(RESET)\n'
	@$(DOCKER) run --rm $(DOCKER_SND) $(DOCKER_ASAN) $(DOCKER_IMAGE)
	@printf '$(GREEN)✓ docker-test passed$(RESET)\n'

.PHONY: docker-clean
docker-clean:
	@printf '$(BLUE)Removing $(DOCKER_IMAGE)...$(RESET)\n'
	@$(DOCKER) rmi -f $(DOCKER_IMAGE) 2>/dev/null || true
	@printf '$(GREEN)✓ removed$(RESET)\n'

# --- Real ALSA runtime coverage on macOS (multipass VM) ---------------------
# Docker alone can't run the ALSA runtime rows on a Mac (no /dev/snd/seq in the
# shared LinuxKit kernel). A generic-kernel Ubuntu VM can — scripts/vm-test.sh
# boots one, loads snd-virmidi, and runs the full gate there. Override the VM
# name/size via MIDIIO_VM* env vars (see the script header).
VM_NAME ?= midiio-test

.PHONY: vm-test
vm-test:
	@MIDIIO_VM=$(VM_NAME) scripts/vm-test.sh

.PHONY: vm-shell
vm-shell:
	@multipass shell $(VM_NAME)

.PHONY: vm-clean
vm-clean:
	@printf '$(BLUE)Deleting VM $(VM_NAME)...$(RESET)\n'
	@multipass delete --purge $(VM_NAME) 2>/dev/null || true
	@printf '$(GREEN)✓ removed$(RESET)\n'
