#!/usr/bin/env bash
# Requires macOS, Xcode 14+ tools and Bash 3.2+; credentials stay in Keychain.
set -euo pipefail

cd "$(dirname "$0")/.."
CHECK_ONLY=false
if [[ "${1:-}" == --check ]]; then
    CHECK_ONLY=true
    shift
fi
if [[ $# -gt 1 || "${1:-}" == --* ]]; then
    printf '%s\n' 'Usage: notarize_release.sh [--check] [keychain-profile]' >&2
    exit 2
fi
PROFILE="${1:-VantaShot-Notary}"

die() { printf '%s\n' "$*" >&2; exit 1; }
for tool in security codesign xcrun plutil ditto hdiutil shasum; do
    command -v "${tool}" >/dev/null || die "Required tool is missing: ${tool}"
done
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null

# A development certificate must never be mistaken for a distribution identity.
IDENTITIES="$(security find-identity -v -p codesigning)"
CERTIFICATES="$(printf '%s\n' "${IDENTITIES}" | awk '/"Developer ID Application:/ {print $2}')"
[[ -n "${CERTIFICATES}" ]] || die 'Developer ID Application certificate with a private key is missing. Create it in Xcode > Settings > Accounts > Manage Certificates.'
CERT_HASH="${CODE_SIGN_IDENTITY:-}"
if [[ -n "${CERT_HASH}" ]]; then
    MATCH=false
    while IFS= read -r candidate; do
        if [[ "${candidate}" == "${CERT_HASH}" ]]; then MATCH=true; fi
    done <<< "${CERTIFICATES}"
    [[ "${MATCH}" == true ]] || die 'CODE_SIGN_IDENTITY must be the SHA-1 hash of an available Developer ID Application identity.'
else
    CERT_COUNT="$(printf '%s\n' "${CERTIFICATES}" | wc -l | tr -d ' ')"
    [[ "${CERT_COUNT}" == 1 ]] || die 'Multiple Developer ID Application identities found. Set CODE_SIGN_IDENTITY to the intended certificate SHA-1 hash.'
    CERT_HASH="${CERTIFICATES}"
fi

# Validate authentication before building or sending software to Apple.
xcrun notarytool history --keychain-profile "${PROFILE}" --output-format json >/dev/null
if [[ "${CHECK_ONLY}" == true ]]; then
    printf '%s\n' 'Developer ID identity and notarization credentials are ready.'
    exit 0
fi

bash ./bundle-app.sh
bash ./script/verify_release.sh
PLIST=dist/VantaShot.app/Contents/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${BUILD}" =~ ^[0-9]+$ ]] || die 'Bundle version values are invalid.'
ARCH="$(lipo -archs dist/VantaShot.app/Contents/MacOS/VantaShot)"
[[ "${ARCH}" == arm64 || "${ARCH}" == x86_64 ]] || die "Unsupported release architectures: ${ARCH}"

# A unique output directory preserves previous releases and submission records.
mkdir -p dist
OUTPUT="$(mktemp -d "${PWD}/dist/notarized-${VERSION}-${BUILD}.XXXXXX")"
WORK="$(mktemp -d "${OUTPUT}/.stage.XXXXXX")"
cleanup() { rm -rf -- "${WORK}"; }
trap cleanup EXIT
printf 'Submission records: %s\n' "${OUTPUT}"
mkdir -p "${WORK}/image"
APP="${WORK}/image/VantaShot.app"
ditto dist/VantaShot.app "${APP}"
codesign --force --sign "${CERT_HASH}" --options runtime --timestamp \
    --entitlements Resources/Distribution.entitlements "${APP}"
codesign --verify --deep --strict "${APP}"

submit() {
    local archive="$1" label="$2" result result_status
    result="${OUTPUT}/notary-${label}.json"
    printf 'Submitting %s to Apple...\n' "${label}"
    if ! xcrun notarytool submit "${archive}" --keychain-profile "${PROFILE}" \
        --wait --timeout 20m --output-format json > "${result}"; then
        die "Submission/wait failed. Keep ${result} and query its submission ID before submitting again."
    fi
    result_status="$(plutil -extract status raw -o - "${result}")"
    [[ "${result_status}" == Accepted ]] || \
        die "Apple has not accepted ${label}. See ${result}; no final artifact was published."
}

ditto -c -k --keepParent "${APP}" "${WORK}/VantaShot.zip"
submit "${WORK}/VantaShot.zip" app
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
spctl --assess --type execute --verbose=2 "${APP}"

ln -s /Applications "${WORK}/image/Applications"
NAME="VantaShot-${VERSION}-${ARCH}.dmg"
DMG="${WORK}/${NAME}"
hdiutil create -volname "VantaShot ${VERSION}" -srcfolder "${WORK}/image" -format UDZO "${DMG}"
codesign --sign "${CERT_HASH}" --timestamp "${DMG}"
submit "${DMG}" dmg
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"
codesign --verify --strict "${DMG}"
hdiutil verify "${DMG}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}"
mv "${DMG}" "${OUTPUT}/${NAME}"
mv "${APP}" "${OUTPUT}/VantaShot.app"
(
    cd "${OUTPUT}"
    shasum -a 256 "${NAME}" > "${NAME}.sha256"
    shasum -a 256 -c "${NAME}.sha256"
)
printf 'Notarized release: %s/%s\n' "${OUTPUT}" "${NAME}"
