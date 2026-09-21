#!/bin/bash
# Build RMDoc.xcframework — the artefact a consumer links against.
#
# The sources are a SwiftPM package (`Package.swift`), and SwiftPM cannot
# produce a framework: archiving its library product leaves a bare `.o`. So
# `project.yml` beside it declares the same sources as a framework
# target, and this script is the whole pipeline — generate the project, archive
# it once per platform, wrap the frameworks.
#
#   Scripts/build-xcframework.sh                 # -> build/RMDoc.xcframework
#   Scripts/build-xcframework.sh ../some-app/Frameworks
#                                                # and install it there too
#
# The second form is how a consuming application gets a new codec: the path
# names a directory, and `RMDoc.xcframework` inside it is replaced.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
build="$root/build"
output="$build/RMDoc.xcframework"
install_into="${1:-}"

# The version the framework declares. `project.yml` carries a default so that
# a local build needs no ceremony; a release overrides it, because the tag is
# what a consumer resolves and a framework claiming another number is a
# discrepancy nothing reports. Passed to `xcodebuild` rather than written into
# the spec: the generated project is not committed, and a build must not leave
# the tree different from how it found it.
version="${RMDOC_VERSION:-}"
version_settings=()
if [ -n "$version" ]; then
  version_settings+=("MARKETING_VERSION=$version")
  # A monotonic build number is what Xcode wants here, and a tag is not one.
  # The tag itself is the identity; this only has to be present and stable.
  version_settings+=("CURRENT_PROJECT_VERSION=${RMDOC_BUILD:-1}")
  echo "==> version $version"
fi

# `build/` is not in the repository, and the shell opens the archive log
# below before `xcodebuild` ever runs — on a fresh clone that redirect failed
# and took the script with it under `set -e`.
mkdir -p "$build"

# A stale project is worse than none: a source file added since the last run
# would be missing from the archive and nowhere in the diff.
echo "==> generating RMDoc.xcodeproj"
xcodegen generate --quiet

# Cleaned rather than reused. An archive is incremental and an xcframework is
# not: `-create-xcframework` refuses to write over an existing directory, and
# a half-replaced one is the kind of artefact that ships.
rm -rf "$output" "$build"/rmdoc-*.xcarchive

# One archive per platform: `xcodebuild` builds one at a time, and an
# xcframework is exactly the wrapper that carries the results side by side.
# The simulator is its own platform here and not a variant of the device —
# leaving it out gives a framework nobody can develop against, which is a thing
# discovered in the consumer on the day someone opens a simulator.
#
# Fields: archive name | destination | the slices that must be present. The
# expectation differs by platform, so it is data rather than a constant: macOS
# and the simulator are universal, an iOS device is arm64 alone.
platforms="
macos|generic/platform=macOS|arm64 x86_64
ios|generic/platform=iOS|arm64
ios-simulator|generic/platform=iOS Simulator|arm64 x86_64
"

# Collected in the order archived, and handed to `-create-xcframework` in one
# call: the tool takes every slice at once and refuses to add one to a finished
# xcframework.
frameworks=()

while IFS='|' read -r name destination want_archs; do
  [ -n "$name" ] || continue

  archive="$build/rmdoc-$name.xcarchive"
  echo "==> archiving for $name ($want_archs)"
  xcodebuild archive \
    -project RMDoc.xcodeproj \
    -scheme RMDoc \
    -destination "$destination" \
    -archivePath "$archive" \
    -derivedDataPath "$build/derived-data" \
    SKIP_INSTALL=NO \
    "${version_settings[@]+"${version_settings[@]}"}" \
    >"$build/archive-$name.log" 2>&1 \
    || { tail -40 "$build/archive-$name.log"; exit 1; }

  framework="$archive/Products/Library/Frameworks/RMDoc.framework"
  [ -d "$framework" ] || { echo "no framework at $framework"; exit 1; }

# Said out loud, because both are silent failures that only show up in the
# consumer: a static slice is refused by Xcode's copy phase when the framework
# is embedded, and a single-slice one fails the release link of a universal app.
  # A macOS framework is versioned and an iOS one is flat: same wrapper, two
  # shapes, and the binary is the file both agree on.
  binary="$framework/Versions/A/RMDoc"
  [ -f "$binary" ] || binary="$framework/RMDoc"
  [ -f "$binary" ] || { echo "no binary in $framework"; exit 1; }

  case "$(file -b "$binary")" in
    *"dynamically linked shared library"*) ;;
    *) echo "not a dynamic framework: $(file -b "$binary")"; exit 1 ;;
  esac
# Checked and not merely printed: a framework of one slice links here and
# fails the release link of a universal application, which is a failure that
# only ever shows up in the consumer.
  slices="$(lipo -archs "$binary")"
  for want in $want_archs; do
    case " $slices " in
      *" $want "*) ;;
      *) echo "$name: missing $want slice: got '$slices'"; exit 1 ;;
    esac
  done
  echo "==> $name slices: $slices"

  frameworks+=(-framework "$framework")
done <<EOF
$platforms
EOF

echo "==> wrapping into RMDoc.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" -output "$output" >/dev/null

if [ -n "$install_into" ]; then
  [ -d "$install_into" ] || { echo "no such directory: $install_into"; exit 1; }
  rm -rf "$install_into/RMDoc.xcframework"
  cp -R "$output" "$install_into/"
  echo "==> installed into $install_into"
fi

echo "==> $output ($(du -sh "$output" | cut -f1))"
