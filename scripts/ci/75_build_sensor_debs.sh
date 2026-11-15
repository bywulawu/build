#!/usr/bin/env bash
set -euo pipefail

# Builds the userspace sensor stack for gaokun3 (SSC accelerometer and ambient
# light) plus the configuration that ties it to the desktop:
#
#   libssc-gaokun3            Snapdragon Sensor Core client library
#   hexagonrpc-gaokun3        hexagonrpcd with the writable registry support
#   iio-sensor-proxy-gaokun3  iio-sensor-proxy 3.9 with the SSC backend
#   gaokun3-sensors           registry, udev rules, rotation daemon and switch
#
# None of these live in the distro archive, and the proxy is a separate binary
# started through a drop-in, so distribution upgrades never take the sensor
# stack away.

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"

DEB_ARCH="${DEB_ARCH:-arm64}"
DEB_MULTIARCH="${DEB_MULTIARCH:-$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)}"
DEB_MULTIARCH="${DEB_MULTIARCH:-aarch64-linux-gnu}"
DEB_TOPDIR="$WORKDIR/sensor-debbuild"
BUILDROOT_DIR="$WORKDIR/sensor-buildroots"
SRC_DIR="$WORKDIR/sensor-src"
LIBSS_PREFIX="$WORKDIR/sensor-prefix"

LIBSS_REPO="${LIBSS_REPO:-https://codeberg.org/DylanVanAssche/libssc.git}"
LIBSS_COMMIT="${LIBSS_COMMIT:-033e2a32095c024d6dbdfb1d4ae1db4a94be32f1}"
HEXAGONRPC_REPO="${HEXAGONRPC_REPO:-https://github.com/FadyAckad/hexagonrpc.git}"
HEXAGONRPC_COMMIT="${HEXAGONRPC_COMMIT:-40e50412812adce9dddc2be9a4510ebce05eef89}"
IIO_REPO="${IIO_REPO:-https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git}"
IIO_REF="${IIO_REF:-3.9}"

IIO_VERSION="${IIO_REF}-1gaokun3"
SENSORS_VERSION="${SENSORS_VERSION:-1.0-1gaokun3}"

mkdir -p "$ARTIFACT_DIR" "$DEB_TOPDIR" "$BUILDROOT_DIR" "$SRC_DIR"

render_template_to_string() {
  local template_path="$1"
  shift

  local sed_args=()
  while [[ $# -gt 0 ]]; do
    sed_args+=(-e "s|$1|$2|g")
    shift 2
  done

  if [[ ${#sed_args[@]} -eq 0 ]]; then
    cat "$template_path"
    return
  fi

  sed "${sed_args[@]}" "$template_path"
}

build_deb() {
  local template_root="$1"
  local pkg_name="$2"
  local stage_dir="$3"
  local version="$4"
  local description="$5"
  local depends="${6:-}"
  local arch="${7:-$DEB_ARCH}"
  local postinst="${8:-}"

  local deb_dir="$stage_dir/DEBIAN"
  mkdir -p "$deb_dir"
  local depends_line=""
  if [[ -n "$depends" ]]; then
    depends_line="Depends: ${depends}"
  fi

  render_template_to_string \
    "$template_root/DEBIAN/control.in" \
    "@PKG_NAME@" "$pkg_name" \
    "@PKGVER@" "$version" \
    "@ARCH@" "$arch" \
    "@PKG_DESC@" "$description" \
    "@DEPENDS_LINE@" "$depends_line" >"$deb_dir/control"

  if [[ -n "$postinst" ]]; then
    printf '%s\n' "$postinst" >"$deb_dir/postinst"
    chmod 755 "$deb_dir/postinst"
  fi

  dpkg-deb --build --root-owner-group "$stage_dir" "$DEB_TOPDIR/${pkg_name}_${version}_${arch}.deb"
}

fetch_source() {
  local repo="$1"
  local ref="$2"
  local dest="$3"

  rm -rf "$dest"
  git init -q "$dest"
  git -C "$dest" remote add origin "$repo"
  git -C "$dest" fetch -q --depth 1 origin "$ref"
  git -C "$dest" checkout -q FETCH_HEAD
}

# --- build ------------------------------------------------------------------

fetch_source "$LIBSS_REPO" "$LIBSS_COMMIT" "$SRC_DIR/libssc"
LIBSS_UPSTREAM_VERSION="$(sed -n "s/.*version:[[:space:]]*'\([0-9][0-9.]*\)'.*/\1/p" "$SRC_DIR/libssc/meson.build" | head -n1)"
LIBSS_VERSION="${LIBSS_UPSTREAM_VERSION:-0.4.4}+git${LIBSS_COMMIT:0:7}-1gaokun3"
meson setup "$SRC_DIR/libssc/build" "$SRC_DIR/libssc" \
  --prefix="$LIBSS_PREFIX" --libdir=lib --buildtype=release
ninja -C "$SRC_DIR/libssc/build"
ninja -C "$SRC_DIR/libssc/build" install

fetch_source "$HEXAGONRPC_REPO" "$HEXAGONRPC_COMMIT" "$SRC_DIR/hexagonrpc"
HEXAGONRPC_UPSTREAM_VERSION="$(sed -n "s/.*version:[[:space:]]*'\([0-9][0-9.]*\)'.*/\1/p" "$SRC_DIR/hexagonrpc/meson.build" | head -n1)"
HEXAGONRPC_VERSION="${HEXAGONRPC_UPSTREAM_VERSION:-0.5.0}+git${HEXAGONRPC_COMMIT:0:7}-1gaokun3"
meson setup "$SRC_DIR/hexagonrpc/build" "$SRC_DIR/hexagonrpc" \
  --prefix=/usr --libdir="lib/$DEB_MULTIARCH" --buildtype=release
ninja -C "$SRC_DIR/hexagonrpc/build"
rm -rf "$BUILDROOT_DIR/hexagonrpc"
DESTDIR="$BUILDROOT_DIR/hexagonrpc" ninja -C "$SRC_DIR/hexagonrpc/build" install

fetch_source "$IIO_REPO" "$IIO_REF" "$SRC_DIR/iio-sensor-proxy"
git -C "$SRC_DIR/iio-sensor-proxy" apply \
  "$GAOKUN_DIR/packaging/patches/iio-sensor-proxy-startup-race.patch"
PKG_CONFIG_PATH="$LIBSS_PREFIX/lib/pkgconfig" \
  meson setup "$SRC_DIR/iio-sensor-proxy/build" "$SRC_DIR/iio-sensor-proxy" \
  --prefix=/usr --libdir="lib/$DEB_MULTIARCH" --buildtype=release \
  -Dssc-support=enabled -Dtests=false -Dgtk-tests=false
PKG_CONFIG_PATH="$LIBSS_PREFIX/lib/pkgconfig" \
  ninja -C "$SRC_DIR/iio-sensor-proxy/build"
DESTDIR="$BUILDROOT_DIR/iio-sensor-proxy" \
  ninja -C "$SRC_DIR/iio-sensor-proxy/build" install

# --- package ----------------------------------------------------------------

libssc_stage="$BUILDROOT_DIR/libssc-gaokun3"
rm -rf "$libssc_stage"
mkdir -p "$libssc_stage/usr/lib/$DEB_MULTIARCH"
cp -a "$LIBSS_PREFIX/lib/"libssc.so.* "$libssc_stage/usr/lib/$DEB_MULTIARCH/"

build_deb "$GAOKUN_DIR/packaging/deb/libssc-gaokun3" \
  "libssc-gaokun3" "$libssc_stage" "$LIBSS_VERSION" \
  "$(render_template_to_string "$GAOKUN_DIR/packaging/deb/libssc-gaokun3/descriptions/package.in")" \
  "libglib2.0-0, libqmi-glib5, libprotobuf-c1"

hexagonrpc_stage="$BUILDROOT_DIR/hexagonrpc-gaokun3"
rm -rf "$hexagonrpc_stage"
cp -a "$BUILDROOT_DIR/hexagonrpc/." "$hexagonrpc_stage/"
# gaokun3-sensors owns the units; upstream ones would only conflict with it.
rm -rf "$hexagonrpc_stage/usr/lib/$DEB_MULTIARCH/systemd"

build_deb "$GAOKUN_DIR/packaging/deb/hexagonrpc-gaokun3" \
  "hexagonrpc-gaokun3" "$hexagonrpc_stage" "$HEXAGONRPC_VERSION" \
  "$(render_template_to_string "$GAOKUN_DIR/packaging/deb/hexagonrpc-gaokun3/descriptions/package.in")" \
  "libglib2.0-0"

iio_stage="$BUILDROOT_DIR/iio-sensor-proxy-gaokun3"
rm -rf "$iio_stage"
mkdir -p "$iio_stage/usr/libexec"
# Keep only the proxy itself under a name of our own: the distribution package
# still provides the D-Bus policy, the udev rules and the unit we override.
install -Dm755 "$BUILDROOT_DIR/iio-sensor-proxy/usr/libexec/iio-sensor-proxy" \
  "$iio_stage/usr/libexec/iio-sensor-proxy-gaokun3"

build_deb "$GAOKUN_DIR/packaging/deb/iio-sensor-proxy-gaokun3" \
  "iio-sensor-proxy-gaokun3" "$iio_stage" "$IIO_VERSION" \
  "$(render_template_to_string "$GAOKUN_DIR/packaging/deb/iio-sensor-proxy-gaokun3/descriptions/package.in")" \
  "iio-sensor-proxy, libssc-gaokun3, libglib2.0-0, libgudev-1.0-0, libpolkit-gobject-1-0"

sensors_stage="$BUILDROOT_DIR/gaokun3-sensors"
rm -rf "$sensors_stage"
cp -a "$GAOKUN_DIR/packaging/deb/gaokun3-sensors/files/." "$sensors_stage/"

# The checkout carries the developer's umask; ship system modes instead.
find "$sensors_stage" -type d -exec chmod 755 {} +
find "$sensors_stage" -type f -exec chmod 644 {} +
chmod 755 "$sensors_stage/usr/bin/gaokun3-auto-rotate"
# hexagonrpcd writes the sensor registry into this tree at runtime.
find "$sensors_stage/usr/share/qcom/sc8280xp/HUAWEI/gaokun3/sensors/persist" \
  -type d -exec chmod 777 {} +

build_deb "$GAOKUN_DIR/packaging/deb/gaokun3-sensors" \
  "gaokun3-sensors" "$sensors_stage" "$SENSORS_VERSION" \
  "$(render_template_to_string "$GAOKUN_DIR/packaging/deb/gaokun3-sensors/descriptions/package.in")" \
  "iio-sensor-proxy-gaokun3, hexagonrpc-gaokun3, python3-gi, gir1.2-glib-2.0, qrtr-tools, dconf-cli, udev" \
  "all" \
  "$(render_template_to_string "$GAOKUN_DIR/packaging/deb/gaokun3-sensors/DEBIAN/postinst.in")"

# --- manifest ---------------------------------------------------------------

mkdir -p "$ARTIFACT_DIR"
for deb in "$DEB_TOPDIR"/*.deb; do
  cp "$deb" "$ARTIFACT_DIR/"
done

cat >"$ARTIFACT_DIR/sensor-manifest.json" <<EOF
{
  "packages": {
    "libssc": "$(basename "$DEB_TOPDIR/libssc-gaokun3_${LIBSS_VERSION}_${DEB_ARCH}.deb")",
    "hexagonrpc": "$(basename "$DEB_TOPDIR/hexagonrpc-gaokun3_${HEXAGONRPC_VERSION}_${DEB_ARCH}.deb")",
    "iio_sensor_proxy": "$(basename "$DEB_TOPDIR/iio-sensor-proxy-gaokun3_${IIO_VERSION}_${DEB_ARCH}.deb")",
    "sensors": "$(basename "$DEB_TOPDIR/gaokun3-sensors_${SENSORS_VERSION}_all.deb")"
  }
}
EOF
