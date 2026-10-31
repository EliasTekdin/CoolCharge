#!/bin/sh
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"

stage="$(mktemp -d "${TMPDIR:?}coolcharge.XXXXXX")"
work="$(mktemp -d "${TMPDIR:?}coolcharge-work.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${work:?}"' EXIT

project="${APELIN_PROJECT_ROOT:?}"
mkdir -p "$work/slices" "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries" "$stage/DEBIAN"

common_flags="-fobjc-arc -fvisibility=hidden -O2 -I${project}/Sources -DAPELIN_PACKAGE_ID=\"local.apelin.coolcharge\" -DAPELIN_BUILD_ID=\"${APELIN_BUILD_ID}\""
case "$APELIN_BOOTSTRAP" in
  roothide)
    arches="arm64e"
    ;;
  rootless)
    arches="arm64 arm64e"
    ;;
  *)
    echo "unsupported bootstrap: $APELIN_BOOTSTRAP" >&2
    exit 2
    ;;
esac

for arch in $arches; do
  clang -fobjc-arc -fvisibility=hidden -O2 -I"${project}/Sources" \
    '-DAPELIN_PACKAGE_ID="local.apelin.coolcharge"' \
    "-DAPELIN_BUILD_ID=\"${APELIN_BUILD_ID}\"" \
    -arch "$arch" -c "$project/Sources/Tweak.m" -o "$work/$arch.o"
  clang -dynamiclib -arch "$arch" "$work/$arch.o" \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework IOKit \
    -install_name "@rpath/CoolCharge.dylib" \
    -o "$work/slices/CoolCharge-$arch.dylib"
done

if [ "$APELIN_BOOTSTRAP" = roothide ]; then
  cp "$work/slices/CoolCharge-arm64e.dylib" "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CoolCharge.dylib"
else
  lipo -create "$work/slices/CoolCharge-arm64.dylib" "$work/slices/CoolCharge-arm64e.dylib" \
    -output "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CoolCharge.dylib"
fi
ldid -S "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CoolCharge.dylib"

cat > "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CoolCharge.plist" <<'PLIST'
{
    Filter = {
        Bundles = ("com.apple.springboard");
    };
}
PLIST

cat > "$stage/DEBIAN/control" <<CONTROL
Package: local.apelin.coolcharge
Name: CoolCharge
Version: 0.1.0
Architecture: ${APELIN_ARCHITECTURE}
Description: Cooperative thermal guard and charging telemetry for SpringBoard
Section: Tweaks
Maintainer: Apelin project
Author: Apelin project
Depends: mobilesubstrate
CONTROL

dpkg-deb -b --root-owner-group "$stage" "${APELIN_PACKAGE_DIR:?}/"
