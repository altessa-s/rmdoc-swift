#!/bin/bash
# Select the newest Xcode installed on a CI runner.
#
# `Package.swift` asks for tools 6.3, and a runner image whose default Xcode is
# older fails to parse the manifest at all — with an error that reads like a
# syntax error and is not one. Pinning a version instead would trade that
# failure for a different one: the pinned image eventually stops being offered.
#
# A script and not three copies in the workflows. The rule for choosing an
# Xcode is the kind of thing that changes once and has to change everywhere,
# and there are already three places that ask for it — both jobs of CI that
# compile, and the release.
#
# CI only: it runs `sudo xcode-select`, which is a machine-wide change no local
# build should make behind anyone's back.
set -euo pipefail

if [ "${CI:-}" != "true" ]; then
  echo "refusing to switch Xcode outside CI (set CI=true to override)" >&2
  exit 1
fi

# A glob rather than `ls`: parsing `ls` breaks on names the shell would have
# handled, and shellcheck is right to say so (SC2012).
#
# Betas are left out. The runner images carry them beside the releases, named
# `Xcode_26.1_beta.app`, and `sort -V` puts a beta after the release it
# precedes — so the newest by name would be the one whose toolchain is still
# changing, and a red build on a Tuesday would be a compiler bug nobody here
# can fix. Only when nothing else is installed does a beta get chosen.
shopt -s nullglob nocaseglob
installed=()
betas=()
for app in /Applications/Xcode*.app; do
  case "$app" in
    *beta*|*Beta*) betas+=("$app") ;;
    *) installed+=("$app") ;;
  esac
done
if [ ${#installed[@]} -eq 0 ]; then
  installed=("${betas[@]+"${betas[@]}"}")
fi
if [ ${#installed[@]} -eq 0 ]; then
  echo "no Xcode found under /Applications" >&2
  exit 1
fi

# Sorted by version and not by name: Xcode_9 must not win over Xcode_26.
newest="$(printf '%s\n' "${installed[@]}" | sort -V | tail -1)"
echo "==> selecting $newest"
sudo xcode-select -s "$newest"
swift --version
