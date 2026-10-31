#!/bin/sh
set -eu

: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}" "${APELIN_CONFIGURATION:?}" "${APELIN_TOOLCHAIN_BIN:?}"

stage="$(mktemp -d "${TMPDIR:?}coolcharge.XXXXXX")"
work="$(mktemp -d "${TMPDIR:?}coolcharge-work.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${work:?}"' EXIT

project="${APELIN_PROJECT_ROOT:?}"
prefs_support="${APELIN_TOOLCHAIN_BIN%/usr/lib/apelin/toolchains/*}/usr/share/apelin/development/wiki.qaq.apelin.dev.preferences/support"
mkdir -p \
  "$work/slices" \
  "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries" \
  "$stage${APELIN_PREFIX}/Library/PreferenceBundles/CoolChargePrefs.bundle" \
  "$stage${APELIN_PREFIX}/Library/PreferenceLoader/Preferences" \
  "$stage/DEBIAN"

case "$APELIN_BOOTSTRAP" in
  roothide)
    arches="arm64e"
    bootstrap_define="-DAPELIN_BOOTSTRAP_ROOTHIDE=1"
    ;;
  rootless)
    arches="arm64 arm64e"
    bootstrap_define="-DAPELIN_BOOTSTRAP_ROOTLESS=1"
    ;;
  *)
    echo "unsupported bootstrap: $APELIN_BOOTSTRAP" >&2
    exit 2
    ;;
esac

case "$APELIN_CONFIGURATION" in
  debug)
    optimization="-O0 -g"
    ;;
  release)
    optimization="-O2"
    ;;
  *)
    echo "unsupported configuration: $APELIN_CONFIGURATION" >&2
    exit 2
    ;;
esac

for arch in $arches; do
  # shellcheck disable=SC2086
  clang $optimization -fobjc-arc -fvisibility=hidden \
    -I"$project/Sources" $bootstrap_define \
    '-DAPELIN_PACKAGE_ID="com.ilyastekdin.coolcharge"' \
    "-DAPELIN_BUILD_ID=\"${APELIN_BUILD_ID}\"" \
    -arch "$arch" -c "$project/Sources/Tweak.m" -o "$work/$arch-tweak.o"
  clang -dynamiclib -arch "$arch" "$work/$arch-tweak.o" \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework IOKit \
    -install_name "@rpath/CoolCharge.dylib" \
    -o "$work/slices/CoolCharge-$arch.dylib"

  # The Preferences framework is private on iOS; Apelin supplies its small
  # link stub and declarations through the registered Preferences extension.
  # shellcheck disable=SC2086
  clang $optimization -fobjc-arc -fvisibility=hidden \
    -I"$project/Sources" -I"$prefs_support/include" $bootstrap_define \
    '-DAPELIN_PACKAGE_ID="com.ilyastekdin.coolcharge"' \
    "-DAPELIN_BUILD_ID=\"${APELIN_BUILD_ID}\"" \
    -arch "$arch" -c "$project/Sources/Prefs.m" -o "$work/$arch-prefs.o"
  clang -bundle -arch "$arch" "$work/$arch-prefs.o" \
    -F"$prefs_support/stubs" \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework IOKit -framework Preferences \
    -o "$work/slices/CoolChargePrefs-$arch"
done

tweak_path="$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CoolCharge.dylib"
prefs_path="$stage${APELIN_PREFIX}/Library/PreferenceBundles/CoolChargePrefs.bundle/CoolChargePrefs"
if [ "$APELIN_BOOTSTRAP" = roothide ]; then
  cp "$work/slices/CoolCharge-arm64e.dylib" "$tweak_path"
  cp "$work/slices/CoolChargePrefs-arm64e" "$prefs_path"
else
  lipo -create "$work/slices/CoolCharge-arm64.dylib" "$work/slices/CoolCharge-arm64e.dylib" -output "$tweak_path"
  lipo -create "$work/slices/CoolChargePrefs-arm64" "$work/slices/CoolChargePrefs-arm64e" -output "$prefs_path"
fi
ldid -S "$tweak_path"
ldid -S "$prefs_path"
chmod 0755 "$prefs_path"

cat > "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CoolCharge.plist" <<'PLIST'
{
    Filter = {
        Bundles = ("com.apple.springboard");
    };
}
PLIST

cp "$project/Resources/Info.plist" "$stage${APELIN_PREFIX}/Library/PreferenceBundles/CoolChargePrefs.bundle/Info.plist"
cp "$project/Resources/Root.plist" "$stage${APELIN_PREFIX}/Library/PreferenceBundles/CoolChargePrefs.bundle/Root.plist"
cp "$project/Packaging/entry.plist" "$stage${APELIN_PREFIX}/Library/PreferenceLoader/Preferences/CoolChargePrefs.plist"
chmod 0644 \
  "$stage${APELIN_PREFIX}/Library/MobileSubstrate/DynamicLibraries/CoolCharge.plist" \
  "$stage${APELIN_PREFIX}/Library/PreferenceBundles/CoolChargePrefs.bundle/Info.plist" \
  "$stage${APELIN_PREFIX}/Library/PreferenceBundles/CoolChargePrefs.bundle/Root.plist" \
  "$stage${APELIN_PREFIX}/Library/PreferenceLoader/Preferences/CoolChargePrefs.plist"

cat > "$stage/DEBIAN/control" <<CONTROL
Package: com.ilyastekdin.coolcharge
Name: CoolCharge
Version: 0.1.1
Architecture: ${APELIN_ARCHITECTURE}
Description: Cooperative thermal guard, charging telemetry, and live Settings preview for SpringBoard
Section: Tweaks
Maintainer: Apelin project
Author: Apelin project
Depends: mobilesubstrate, preferenceloader
CONTROL

dpkg-deb -b --root-owner-group "$stage" "${APELIN_PACKAGE_DIR:?}/"
