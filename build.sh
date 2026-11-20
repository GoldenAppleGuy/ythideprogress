#!/bin/bash
# Builds YTHideProgress for all three package schemes into packages/:
#   rootless (iphoneos-arm64, /var/jb), roothide (iphoneos-arm64e, .jbroot) and rootful (iphoneos-arm, /).
# Also copies the YouTube part's dylib to packages/YTHideProgress.dylib for injecting into a sideloaded
# YouTube app (rootless build; it uses no jailbreak paths).
# Uses $THEOS (default /opt/theos) and, for roothide, roothide's Theos fork in $THEOS_ROOTHIDE
# (default ~/theos-roothide, from https://github.com/roothide/theos). Compiler overrides (TARGET_CC etc.) are passed through.
set -e
cd "$(dirname "$0")"
export THEOS="${THEOS:-/opt/theos}"
rm -rf packages
make clean >/dev/null
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
cp .theos/obj/YTHideProgress.dylib packages/YTHideProgress.dylib
make clean >/dev/null
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=
make clean THEOS="${THEOS_ROOTHIDE:-$HOME/theos-roothide}" >/dev/null
make package FINALPACKAGE=1 THEOS="${THEOS_ROOTHIDE:-$HOME/theos-roothide}" THEOS_PACKAGE_SCHEME=roothide
make clean >/dev/null
ls -1 packages
