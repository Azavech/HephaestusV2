#!/bin/bash
# Builds the executables with SwiftPM and the guest agent of the virtual machines with swiftc,
# assembles HephaestusV2.app with the Updater and the agent in Contents/Helpers, writes its
# Info.plist values and signs it; with the notarization secrets it also notarizes and staples it
# (docs/ci.md › App bundle).
#
#   scripts/build-app.sh --version <X.Y.Z> --build <N> --repository <owner/name>
#                        [--configuration release|debug] [--arch universal|native] [--output <folder>]
#
# Signing: Developer ID when MACOS_CERTIFICATE_P12_BASE64 and MACOS_CERTIFICATE_PASSWORD are set,
# ad-hoc otherwise; notarization when NOTARY_KEY_ID, NOTARY_ISSUER_ID and NOTARY_KEY_P8_BASE64 are
# also set. Messages go to standard error; the result line goes to standard output. Nothing secret,
# no identity, certificate subject or Team ID is ever printed.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd -P)

usage() {
  cat >&2 << 'USAGE'
usage: scripts/build-app.sh --version <X.Y.Z> --build <N> --repository <owner/name>
                            [--configuration release|debug] [--arch universal|native] [--output <folder>]
USAGE
  exit 2
}

fail() {
  echo "build-app.sh: $*" >&2
  exit 1
}

# The temporary folder and keychain of Developer ID signing, removed on exit.
temporary=""
keychain=""
saved_keychains=()
keychains_changed=0

cleanup() {
  local status=$?
  if [ "$keychains_changed" -eq 1 ] && [ "${#saved_keychains[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${saved_keychains[@]}" || true
  fi
  if [ -n "$keychain" ]; then
    security delete-keychain "$keychain" > /dev/null 2>&1 || true
  fi
  if [ -n "$temporary" ]; then
    rm -rf "$temporary"
  fi
  # Exit statuses: 0 success, 1 failure, 2 usage error.
  if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
    exit 1
  fi
  exit "$status"
}
trap cleanup EXIT

# An empty variable counts as unset.
is_set() {
  [ -n "${!1:-}" ]
}

# MARK: Options

version=""
build=""
repository=""
configuration="release"
arch="universal"
output="build"
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --version) version=$2 ;;
    --build) build=$2 ;;
    --repository) repository=$2 ;;
    --configuration) configuration=$2 ;;
    --arch) arch=$2 ;;
    --output) output=$2 ;;
    *) usage ;;
  esac
  shift 2
done

version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
build_pattern='^(0|[1-9][0-9]*)$'
repository_pattern='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
[[ $version =~ $version_pattern ]] || usage
[[ $build =~ $build_pattern ]] || usage
[[ $repository =~ $repository_pattern ]] || usage
case "$configuration" in release | debug) ;; *) usage ;; esac
case "$arch" in universal | native) ;; *) usage ;; esac
[ -n "$output" ] || usage

archs=()
if [ "$arch" = "universal" ]; then
  archs=(--arch arm64 --arch x86_64)
fi

# MARK: 1. The output folder

case "$output" in
  /*) out=$output ;;
  *) out="$root/$output" ;;
esac
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
app="$out/HephaestusV2.app"
work="$out/work"
rm -rf "$app" "$work"
mkdir -p "$work"

# MARK: 2. The Updater's Info.plist

cp Resources/Updater-Info.plist "$work/Updater-Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$work/Updater-Info.plist"
plutil -replace CFBundleVersion -string "$build" "$work/Updater-Info.plist"

# MARK: 3 to 6. The executables

swift build -c "$configuration" ${archs[@]+"${archs[@]}"} --product HephaestusV2 >&2
swift build -c "$configuration" ${archs[@]+"${archs[@]}"} --product Updater \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$work/Updater-Info.plist" >&2
# The guest agent runs in the guests of the virtual machines, on Apple silicon and on macOS 12 and
# later; SwiftPM builds every target for macOS 26, so its sources are compiled on their own.
xcrun swiftc -O -target arm64-apple-macos12.0 -module-name HephaestusAgent -o "$work/HephaestusAgent" \
  Sources/HephaestusAgent/*.swift >&2
bin=$(swift build -c "$configuration" ${archs[@]+"${archs[@]}"} --show-bin-path)

if [ -d "$bin/PackageFrameworks" ] && [ -n "$(ls -A "$bin/PackageFrameworks")" ]; then
  fail "dynamic frameworks are not supported"
fi

# MARK: 7. The bundle

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/HephaestusV2" "$app/Contents/MacOS/HephaestusV2"
cp "$bin/Updater" "$app/Contents/Helpers/Updater"
cp "$work/HephaestusAgent" "$app/Contents/Helpers/HephaestusAgent"
for bundle in "$bin"/*.bundle; do
  [ -d "$bundle" ] || continue
  name=$(basename "$bundle")
  case "$name" in
    *Tests.bundle) continue ;;
  esac
  ditto "$bundle" "$app/Contents/Resources/$name"
done
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/install-agent.sh "$app/Contents/Resources/install-agent.sh"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build" "$app/Contents/Info.plist"
plutil -replace HephaestusReleaseRepository -string "$repository" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# MARK: 8. Checks

plutil -lint "$app/Contents/Info.plist" >&2
if [ "$arch" = "universal" ]; then
  for executable in "$app/Contents/MacOS/HephaestusV2" "$app/Contents/Helpers/Updater"; do
    architectures=" $(lipo -archs "$executable") "
    case "$architectures" in
      *" arm64 "*) ;;
      *) fail "$(basename "$executable") is not universal: $architectures" ;;
    esac
    case "$architectures" in
      *" x86_64 "*) ;;
      *) fail "$(basename "$executable") is not universal: $architectures" ;;
    esac
  done
fi
case " $(lipo -archs "$app/Contents/Helpers/HephaestusAgent") " in
  *" arm64 "*) ;;
  *) fail "HephaestusAgent is not built for arm64" ;;
esac

# MARK: 9. Signing

# docs/ci.md › Developer ID identity: a temporary keychain holding the certificate, first in the
# user search list while the script runs. Sets `identity` without printing it.
identity=""
developer_id_identity() {
  temporary=$(mktemp -d)
  local password
  password=$(uuidgen)
  keychain="$temporary/signing.keychain-db"
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"

  (umask 077 && printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$temporary/certificate.p12")
  chmod 600 "$temporary/certificate.p12"
  security import "$temporary/certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >&2
  rm -f "$temporary/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null

  local line
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#\"}
    line=${line%\"}
    [ -n "$line" ] && saved_keychains+=("$line")
  done < <(security list-keychains -d user)
  keychains_changed=1
  security list-keychains -d user -s "$keychain" ${saved_keychains[@]+"${saved_keychains[@]}"}

  identity=$(security find-identity -v -p codesigning "$keychain" | awk '/Developer ID Application/ { print $2; exit }')
  [ -n "$identity" ] || fail "the certificate holds no Developer ID Application identity"
}

# The Updater and the guest agent are signed first, then the app, whose signature seals both. The
# entitlements go to the app in both modes, so that ad-hoc builds can run virtual machines too.
updater_identifier="ca.azavech.hephaestusv2.updater"
agent_identifier="ca.azavech.hephaestusv2.agent"
if is_set MACOS_CERTIFICATE_P12_BASE64 && is_set MACOS_CERTIFICATE_PASSWORD; then
  developer_id_identity
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" \
    --identifier "$updater_identifier" "$app/Contents/Helpers/Updater"
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" \
    --identifier "$agent_identifier" "$app/Contents/Helpers/HephaestusAgent"
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" \
    --entitlements Resources/HephaestusV2.entitlements "$app"
  signing="Developer ID"
else
  if is_set MACOS_CERTIFICATE_P12_BASE64 || is_set MACOS_CERTIFICATE_PASSWORD; then
    echo "build-app.sh: MACOS_CERTIFICATE_P12_BASE64 and MACOS_CERTIFICATE_PASSWORD must both be set; signing ad-hoc" >&2
  fi
  codesign --force --sign - --identifier "$updater_identifier" "$app/Contents/Helpers/Updater"
  codesign --force --sign - --identifier "$agent_identifier" "$app/Contents/Helpers/HephaestusAgent"
  codesign --force --sign - --entitlements Resources/HephaestusV2.entitlements "$app"
  signing="ad-hoc"
fi
codesign --verify --deep --strict "$app"

# MARK: 10. Notarization

notarize() {
  (umask 077 && printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$temporary/AuthKey.p8")
  chmod 600 "$temporary/AuthKey.p8"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary/notarize.zip"
  local key_options=(--key "$temporary/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  xcrun notarytool submit "$temporary/notarize.zip" "${key_options[@]}" --wait --timeout 1h --output-format json \
    > "$temporary/notary.json" || true
  local status id
  status=$(jq -r '.status // "unknown"' "$temporary/notary.json" 2> /dev/null || echo unknown)
  if [ "$status" != "Accepted" ]; then
    id=$(jq -r '.id // empty' "$temporary/notary.json" 2> /dev/null || true)
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" "${key_options[@]}" | jq '.issues' >&2 || true
    fi
    fail "notarization failed: $status"
  fi
  xcrun stapler staple "$app" >&2
  xcrun stapler validate "$app" >&2
}

notary_count=0
for variable in NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY_P8_BASE64; do
  if is_set "$variable"; then
    notary_count=$((notary_count + 1))
  fi
done
if [ "$notary_count" -eq 3 ]; then
  if [ "$signing" = "Developer ID" ]; then
    notarize
    signing="Developer ID, notarized"
  else
    echo "build-app.sh: notarization skipped: the app is signed ad-hoc" >&2
  fi
elif [ "$notary_count" -gt 0 ]; then
  echo "build-app.sh: notarization skipped: NOTARY_KEY_ID, NOTARY_ISSUER_ID and NOTARY_KEY_P8_BASE64 must all be set" >&2
fi

# MARK: 11. Result

echo "$app v$version($build), $signing"
