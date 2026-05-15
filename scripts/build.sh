#!/usr/bin/env bash
set -euo pipefail

# Build a CopyCauldron.app bundle from the SPM executable.
# Usage:
#   ./scripts/build.sh            # debug build into .build/CopyCauldron.app
#   ./scripts/build.sh release    # release build

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="CopyCauldron"
BUNDLE_ID="com.copycauldron.app"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "→ Building Swift package (${CONFIG}) for arm64..."
swift build -c "${CONFIG}" --arch arm64
ARM_BIN_PATH=$(swift build -c "${CONFIG}" --arch arm64 --show-bin-path)
ARM_BIN="${ARM_BIN_PATH}/${APP_NAME}"

echo "→ Building Swift package (${CONFIG}) for x86_64..."
swift build -c "${CONFIG}" --arch x86_64
X86_BIN_PATH=$(swift build -c "${CONFIG}" --arch x86_64 --show-bin-path)
X86_BIN="${X86_BIN_PATH}/${APP_NAME}"

if [[ ! -x "${ARM_BIN}" || ! -x "${X86_BIN}" ]]; then
    echo "✗ One of the per-arch binaries is missing"
    echo "  arm64: ${ARM_BIN} (exists: $(test -x "${ARM_BIN}" && echo yes || echo no))"
    echo "  x86_64: ${X86_BIN} (exists: $(test -x "${X86_BIN}" && echo yes || echo no))"
    exit 1
fi

echo "→ Fusing arm64 + x86_64 into a universal binary..."
UNIVERSAL_BIN="${BUILD_DIR}/${APP_NAME}-universal"
lipo -create -output "${UNIVERSAL_BIN}" "${ARM_BIN}" "${X86_BIN}"
EXEC_BIN="${UNIVERSAL_BIN}"

if [[ ! -x "${EXEC_BIN}" ]]; then
    echo "✗ Universal binary not found at ${EXEC_BIN}"
    exit 1
fi

echo "→ Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

cp -X "${EXEC_BIN}" "${MACOS}/${APP_NAME}"
cp -X "Resources/Info.plist" "${CONTENTS}/Info.plist"
cp -X Resources/MenuBarIconTemplate* "${RESOURCES}/"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp -X Resources/AppIcon.icns "${RESOURCES}/AppIcon.icns"
fi

# Pick the signing identity up front, BEFORE stripping, because the security
# lookup takes long enough for iCloud Drive to re-add com.apple.FinderInfo to
# the bundle root and break codesign.
SIGN_IDENTITY="${COPYCAULDRON_SIGN_IDENTITY:-dj}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${SIGN_IDENTITY}\""; then
    SIGN_LABEL="${SIGN_IDENTITY}"
else
    SIGN_IDENTITY="-"
    SIGN_LABEL="ad-hoc"
fi

# Strip extended attributes and codesign immediately. iCloud's file provider
# can re-attach com.apple.FinderInfo to a fresh .app directory if there's any
# delay between the strip and the sign, so we keep them tight here.
echo "→ Signing with identity: ${SIGN_LABEL}..."
strip_and_sign() {
    xattr -cr "${APP_DIR}" 2>/dev/null || true
    find "${APP_DIR}" -exec xattr -c {} + 2>/dev/null || true
    for attr in com.apple.FinderInfo com.apple.fileprovider.fpfs#P com.apple.ResourceFork; do
        find "${APP_DIR}" -exec xattr -d "${attr}" {} + 2>/dev/null || true
        xattr -d "${attr}" "${APP_DIR}" 2>/dev/null || true
    done
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}"
}
# Retry a couple times in case iCloud re-stamps the bundle between strip+sign.
for attempt in 1 2 3; do
    if strip_and_sign 2>/tmp/copycauldron-codesign.err; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        cat /tmp/copycauldron-codesign.err
        exit 1
    fi
done

echo "✓ Built ${APP_DIR}"
echo ""
echo "Run:    open ${APP_DIR}"
echo "Logs:   log stream --predicate 'process == \"${APP_NAME}\"'"
