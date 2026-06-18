#!/usr/bin/env bash
#
# vm-test.sh — run midiio's full Linux gate on a Mac with the ALSA *runtime*
# rows actually executing.
#
# Why a VM (not just Docker): the ALSA sequencer device /dev/snd/seq is created
# by a kernel module (snd-seq). Containers share the host kernel, and on macOS
# that's Docker Desktop's stripped LinuxKit kernel with no sound modules — so a
# container alone can never have /dev/snd/seq. A real Linux VM running Ubuntu's
# *generic* kernel can: that kernel builds snd-seq/snd-virmidi (shipped in
# linux-modules-extra), unlike the azure/LinuxKit cloud kernels. So we boot a
# generic-kernel Ubuntu VM via multipass, load the virtual sequencer there, and
# run the suite inside it — the runtime rows light up because /dev/snd/seq is
# present. See mk/docker.mk for the Docker-only (runtime-rows-skip) harness.
#
# Idempotent: first run launches + provisions the VM (~a few minutes); later
# runs reuse it and just re-sync the source and re-run the gate.
#
#   make vm-test     # this script
#   make vm-shell    # shell into the VM
#   make vm-clean    # delete the VM
#
set -euo pipefail

VM="${MIDIIO_VM:-midiio-test}"
RELEASE="${MIDIIO_VM_RELEASE:-24.04}"
CPUS="${MIDIIO_VM_CPUS:-2}"
MEM="${MIDIIO_VM_MEM:-2G}"
DISK="${MIDIIO_VM_DISK:-12G}"
RUN_CMD="${MIDIIO_VM_CMD:-rebar3 as test check && make asan}"

say() { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m! %s\033[0m\n' "$*"; }

if ! command -v multipass >/dev/null 2>&1; then
  warn "multipass is not installed."
  echo  "   Install it (one-time) with:"
  echo  "       brew install --cask multipass"
  echo  "   then re-run 'make vm-test'."
  exit 1
fi

# 1. Launch the VM if we don't have it yet.
if ! multipass info "$VM" >/dev/null 2>&1; then
  say "launching VM '$VM' (ubuntu $RELEASE, generic kernel)…"
  multipass launch "$RELEASE" --name "$VM" --cpus "$CPUS" --memory "$MEM" --disk "$DISK"
else
  multipass start "$VM" >/dev/null 2>&1 || true
fi

# 2. Provision: build toolchain + ALSA + the sequencer module, then load it.
#    Runs every invocation but is idempotent (apt + modprobe are no-ops once
#    satisfied). The chmod opens /dev/snd/seq to the unprivileged 'ubuntu' user
#    that runs the tests (it isn't in the audio group).
say "provisioning (toolchain, ALSA, virtual sequencer)…"
multipass exec "$VM" -- sudo bash -s <<'PROVISION'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v rebar3 >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y --no-install-recommends \
      build-essential git erlang rebar3 libasound2-dev alsa-utils
fi

# The ALSA sequencer modules live in linux-modules-extra for the running kernel.
apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true
modprobe snd-virmidi 2>/dev/null || modprobe snd-seq 2>/dev/null || true

if [ -e /dev/snd/seq ]; then
  chmod a+rw /dev/snd/seq
  # snd-virmidi exposes raw MIDI nodes too; open them so enumeration can see them.
  chmod a+rw /dev/snd/midi* 2>/dev/null || true
  echo "SEQ_OK"
else
  echo "SEQ_MISSING"
fi
PROVISION

# 3. Confirm the sequencer is actually present; if the cloud kernel flavour
#    lacks it, fall back to the full generic kernel (needs one reboot).
if multipass exec "$VM" -- test -e /dev/snd/seq; then
  ok "/dev/snd/seq present in '$VM' — ALSA runtime rows WILL run"
else
  warn "no /dev/snd/seq: this kernel flavour has no snd-seq module."
  say  "installing linux-generic (one-time); a reboot is needed…"
  multipass exec "$VM" -- sudo bash -c \
    'DEBIAN_FRONTEND=noninteractive apt-get install -y linux-generic'
  multipass restart "$VM"
  warn "VM rebooted into the generic kernel. Re-run 'make vm-test' to finish."
  exit 0
fi

# 4. Ship a CLEAN source snapshot (committed tree only — no _build, no host
#    .so, no .git) and unpack it fresh in the VM.
say "syncing source into the VM…"
TARBALL="$(mktemp -t midiio-src.XXXXXX).tar"
trap 'rm -f "$TARBALL"' EXIT
git archive --format=tar -o "$TARBALL" HEAD
multipass transfer "$TARBALL" "$VM:/home/ubuntu/midiio-src.tar"
multipass exec "$VM" -- bash -c \
  'rm -rf ~/midiio && mkdir -p ~/midiio && tar -xf ~/midiio-src.tar -C ~/midiio'

# 5. Run the full gate in the VM (runtime rows included).
say "running the full Linux gate in '$VM':  $RUN_CMD"
multipass exec "$VM" -- bash -lc "cd ~/midiio && { $RUN_CMD; }"
ok "vm-test passed (with ALSA runtime coverage)"
echo "   VM '$VM' persists; re-run 'make vm-test' anytime, or 'make vm-clean' to remove it."
