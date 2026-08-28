#!/usr/bin/env bash
# Deterministic public AArch64 build for Merchant of the Skies.
# The pinned offline Debian Buster image supplies the low-glibc toolchain. The
# target firmware sysroot is mounted read-only for SDL/EGL/GLES headers only.
set -euo pipefail

PORT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
OUTPUT=${MS_UNIVERSAL_OUTPUT:-build/merchantskies-nextos}
BUILDER_IMAGE=playfetch-builder:buster
BUILDER_IMAGE_ID=sha256:036c7910ea53bc78cc213452afa92fa83d55de1c51ae54f315af58b5a41a45cf
export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1786233600}

fail() {
  printf 'merchantskies build error: %s\n' "$*" >&2
  exit 1
}

case $OUTPUT in
  /*|*../*|../*|*/..|..)
    fail "MS_UNIVERSAL_OUTPUT must stay inside the port directory"
    ;;
esac

if [[ ${MS_BUSTER_IN_CONTAINER:-0} != 1 ]]; then
  NEXTOS_ROOT=${NEXTOS_ROOT:-/mnt/ARQUIVOS/NextOS-Elite-Edition}
  NEXTOS_SYSROOT=${NEXTOS_SYSROOT:-}
  if [[ -z $NEXTOS_SYSROOT ]]; then
    while IFS= read -r candidate; do
      [[ -d $candidate/aarch64-libreelec-linux-gnu/sysroot/usr/include/SDL2 ]] ||
        continue
      NEXTOS_SYSROOT=$candidate/aarch64-libreelec-linux-gnu/sysroot
    done < <(
      find -H "$NEXTOS_ROOT" -maxdepth 2 -type d \
        -path '*/build.NextOS-Retro-Elite-Edition-Amlogic-old.aarch64-*/toolchain' \
        -print | sort -V
    )
    [[ -n $NEXTOS_SYSROOT ]] ||
      fail "set NEXTOS_SYSROOT to a read-only sysroot containing SDL2/EGL/GLES headers"
  fi
  [[ -d $NEXTOS_SYSROOT/usr/include/SDL2 ]] ||
    fail "SDL2 headers are missing below NEXTOS_SYSROOT"
  command -v docker >/dev/null 2>&1 || fail "docker is required for the public build"
  ACTUAL_IMAGE_ID=$(docker image inspect "$BUILDER_IMAGE" \
    --format '{{.Id}}' 2>/dev/null) ||
    fail "offline builder image is missing: $BUILDER_IMAGE"
  [[ $ACTUAL_IMAGE_ID == "$BUILDER_IMAGE_ID" ]] ||
    fail "offline builder image digest changed: $ACTUAL_IMAGE_ID"

  # Create the output directory as the invoking user before Docker starts.
  # Otherwise a new nested output directory would be owned by container root,
  # preventing the hermetic host gate from cleaning its exact temporary tree.
  OUTPUT_DIR=${OUTPUT%/*}
  [[ $OUTPUT_DIR != "$OUTPUT" ]] || OUTPUT_DIR=.
  mkdir -p -- "$PORT_DIR/$OUTPUT_DIR"
  [[ -d $PORT_DIR/$OUTPUT_DIR && ! -L $PORT_DIR/$OUTPUT_DIR ]] ||
    fail "output parent is not a real directory"

  exec docker run --rm --network none \
    -e MS_BUSTER_IN_CONTAINER=1 \
    -e MS_UNIVERSAL_OUTPUT="$OUTPUT" \
    -e MS_HOST_UID="$(id -u)" \
    -e MS_HOST_GID="$(id -g)" \
    -e LC_ALL=C -e TZ=UTC -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -v "$PORT_DIR":/repo \
    -v "$NEXTOS_SYSROOT":/nxsr:ro \
    "$BUILDER_IMAGE_ID" \
    bash /repo/build-universal.sh
fi

for tool in aarch64-linux-gnu-gcc aarch64-linux-gnu-nm \
            aarch64-linux-gnu-readelf aarch64-linux-gnu-strip file strings; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "tool is missing from the pinned builder: $tool"
done

CC=aarch64-linux-gnu-gcc
NM=aarch64-linux-gnu-nm
READELF=aarch64-linux-gnu-readelf
STRIP=aarch64-linux-gnu-strip
cd /repo
mkdir -p -- "$(dirname -- "$OUTPUT")"

OBJDIR=$(mktemp -d)
STUBDIR=$(mktemp -d)
trap 'rm -rf -- "$OBJDIR" "$STUBDIR"' EXIT INT TERM

mapfile -t SOURCES < <(find src -maxdepth 1 -type f -name '*.c' -print | sort)
[[ ${#SOURCES[@]} -gt 0 ]] || fail "no C sources found"
OBJS=()
for source in "${SOURCES[@]}"; do
  object=$OBJDIR/$(basename "${source%.c}").o
  "$CC" -std=gnu11 \
    -I src \
    -idirafter /nxsr/usr/include \
    -idirafter /nxsr/usr/include/SDL2 \
    -O2 -fPIE -fno-strict-aliasing -fno-omit-frame-pointer \
    -ffile-prefix-map=/repo=. -fdebug-prefix-map=/repo=. \
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
    -c "$source" -o "$object"
  OBJS+=("$object")
done

# Record the firmware SDL SONAME without linking against a high-glibc target
# library. All direct SDL imports are satisfied by this link-only stub.
UNDEFINED=$(
  "$NM" --undefined-only "${OBJS[@]}" 2>/dev/null |
    awk '{print $NF}' | sort -u
)
: > "$STUBDIR/sdl.c"
while IFS= read -r symbol; do
  [[ $symbol == SDL_* ]] || continue
  printf 'void %s(void) {}\n' "$symbol" >> "$STUBDIR/sdl.c"
done <<< "$UNDEFINED"
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libSDL2-2.0.so.0 \
  "$STUBDIR/sdl.c" -o "$STUBDIR/libSDL2.so"

"$CC" -fPIE -pie -rdynamic -o "$OUTPUT" "${OBJS[@]}" \
  -L"$STUBDIR" -Wl,--no-as-needed -lSDL2 -Wl,--as-needed \
  -ldl -lm -lpthread -lz -lgcc_s \
  -Wl,--build-id=sha1 -Wl,-z,relro,-z,now,-z,noexecstack
"$STRIP" --strip-debug "$OUTPUT"
chmod 0755 "$OUTPUT"

MACHINE=$("$READELF" -h "$OUTPUT" |
  sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
[[ $MACHINE == AArch64 ]] || fail "unexpected ELF machine: $MACHINE"
INTERPRETER=$("$READELF" -lW "$OUTPUT" |
  sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
[[ $INTERPRETER == /lib/ld-linux-aarch64.so.1 ]] ||
  fail "unexpected PT_INTERP: $INTERPRETER"

MAX_GLIBC=$(
  "$READELF" --version-info "$OUTPUT" 2>/dev/null |
    grep -oE 'GLIBC_[0-9]+([.][0-9]+)*' | sort -Vu | tail -1
)
[[ -n $MAX_GLIBC ]] || fail "could not determine GLIBC requirement"
VERSION=${MAX_GLIBC#GLIBC_}
MAJOR=${VERSION%%.*}
MINOR=${VERSION#*.}; MINOR=${MINOR%%.*}
if (( MAJOR > 2 || (MAJOR == 2 && MINOR > 30) )); then
  fail "$OUTPUT requires $MAX_GLIBC (maximum GLIBC_2.30)"
fi

TLS_MEMSZ=$("$READELF" -lW "$OUTPUT" |
  awk '$1 == "TLS" {value=$6} END {print value}')
PAD_LAYOUT=$("$READELF" -sW "$OUTPUT" |
  awk '$4 == "TLS" && $8 == "g_bionic_guard_pad" {value=$2 ":" $3} END {print value}')
[[ $PAD_LAYOUT == 0000000000000000:256 ]] ||
  fail "Bionic guard TLS layout changed: $PAD_LAYOUT"
(( TLS_MEMSZ >= 256 )) || fail "TLS segment no longer covers the Bionic guard"

if "$READELF" -dW "$OUTPUT" | grep -Eq '(RPATH|RUNPATH)'; then
  fail "public loader contains RPATH/RUNPATH"
fi
NEEDED=$("$READELF" -dW "$OUTPUT" |
  awk -F'[][]' '/NEEDED/ {print $2}' | sort)
while IFS= read -r soname; do
  case $soname in
    libc.so.6|libdl.so.2|libgcc_s.so.1|libm.so.6|libpthread.so.0|\
    libSDL2-2.0.so.0|libz.so.1) ;;
    *) fail "unexpected DT_NEEDED: $soname" ;;
  esac
done <<< "$NEEDED"
for required in libc.so.6 libSDL2-2.0.so.0 libz.so.1; do
  grep -Fx "$required" <<< "$NEEDED" >/dev/null ||
    fail "required DT_NEEDED is missing: $required"
done

if strings "$OUTPUT" | grep -Eq '/home/|/mnt/ARQUIVOS/|192[.]168[.]'; then
  fail "public loader contains a private build path or test address"
fi

if [[ -n ${MS_HOST_UID:-} && -n ${MS_HOST_GID:-} ]]; then
  chown "$MS_HOST_UID:$MS_HOST_GID" "$OUTPUT" 2>/dev/null || true
fi

printf 'MERCHANTSKIES UNIVERSAL BUILD OK: %s\n' "$OUTPUT"
printf 'glibc_max=%s interpreter=%s tls_pad=%s tls_memsz=%s\n' \
  "$MAX_GLIBC" "$INTERPRETER" "$PAD_LAYOUT" "$TLS_MEMSZ"
printf 'DT_NEEDED=%s\n' "$(tr '\n' ' ' <<< "$NEEDED")"
file "$OUTPUT"
sha256sum "$OUTPUT"
