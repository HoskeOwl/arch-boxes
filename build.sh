#!/bin/bash
# Build virtual machine images (basic image, cloud image etc.)
# IMAGES="cloud-image,basic" ./build.sh
# ./build.sh to build all images
# ./build.sh list to show all available image options
# ./build.sh help to show usage information

# nounset: "Treat unset variables and parameters [...] as an error when performing parameter expansion."
# errexit: "Exit immediately if [...] command exits with a non-zero status."
set -o nounset -o errexit
shopt -s extglob
readonly DEFAULT_DISK_SIZE="2G"
readonly IMAGE="image.img"
# shellcheck disable=SC2016
readonly MIRROR='https://geo.mirror.pkgbuild.com/$repo/os/$arch'

function init() {
  readonly ORIG_PWD="${PWD}"
  readonly OUTPUT="${PWD}/output"
  local tmpdir
  tmpdir="$(mktemp --dry-run --directory --tmpdir="${PWD}/tmp")"
  readonly TMPDIR="${tmpdir}"
  mkdir -p "${OUTPUT}" "${TMPDIR}"
  if [ -n "${SUDO_UID:-}" ] && [[ -n "${SUDO_GID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${OUTPUT}" "${TMPDIR}"
  fi
  cd "${TMPDIR}"

  readonly MOUNT="${PWD}/mount"
  mkdir "${MOUNT}"
}

# Do some cleanup when the script exits
function cleanup() {
  # We want all the commands to run, even if one of them fails.
  set +o errexit
  if [ -n "${LOOPDEV:-}" ]; then
    losetup -d "${LOOPDEV}"
  fi
  if [ -n "${MOUNT:-}" ] && mountpoint -q "${MOUNT}"; then
    # We do not want risking deleting ex: the package cache
    umount --recursive "${MOUNT}" || exit 1
  fi
  if [ -n "${TMPDIR:-}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

# Create the disk, partitions it, format the partition and mount the filesystem
function setup_disk() {
  truncate -s "${DEFAULT_DISK_SIZE}" "${IMAGE}"
  sgdisk --align-end \
    --clear \
    --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
    --new 0:0:+300M --typecode=0:ef00 --change-name=0:'EFI system partition' \
    --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
    "${IMAGE}"

  LOOPDEV=$(losetup --find --partscan --show "${IMAGE}")
  # Partscan is racy
  wait_until_settled "${LOOPDEV}"
  mkfs.fat -F 32 -S 4096 "${LOOPDEV}p2"
  mkfs.btrfs "${LOOPDEV}p3"
  mount -o compress-force=zstd "${LOOPDEV}p3" "${MOUNT}"
  mount --mkdir "${LOOPDEV}p2" "${MOUNT}/efi"
}

# Install Arch Linux to the filesystem (bootstrap)
function bootstrap() {
  cat <<EOF >pacman.conf
[options]
Architecture = auto

[core]
Include = mirrorlist

[extra]
Include = mirrorlist
EOF
  echo "Server = ${MIRROR}" >mirrorlist

  # We use the hosts package cache
  pacstrap -c -C pacman.conf -K -M "${MOUNT}" base linux grub openssh sudo btrfs-progs dosfstools efibootmgr qemu-guest-agent
  # Workaround for https://gitlab.archlinux.org/archlinux/arch-install-scripts/-/issues/56
  gpgconf --homedir "${MOUNT}/etc/pacman.d/gnupg" --kill gpg-agent
  cp mirrorlist "${MOUNT}/etc/pacman.d/"
}

# Cleanup the image and trim it
function image_cleanup() {
  # Remove pacman key ring for re-initialization
  rm -rf "${MOUNT}/etc/pacman.d/gnupg/"

  # The mkinitcpio autodetect hook removes modules not needed by the
  # running system from the initramfs. This make the image non-bootable
  # on some systems as initramfs lacks the relevant kernel modules.
  # Ex: Some systems need the virtio-scsi kernel module and not the
  # "autodetected" virtio-blk kernel module for disk access.
  #
  # So for the initial install we use the fallback initramfs, and
  # "autodetect" should add the relevant modules to the initramfs when
  # the user updates the kernel.
  cp --reflink=always -a "${MOUNT}/boot/"{initramfs-linux-fallback.img,initramfs-linux.img}

  sync -f "${MOUNT}/etc/os-release"
  fstrim --verbose "${MOUNT}"
  fstrim --verbose "${MOUNT}/efi"
}

# Helper function: wait until a given loop device has settled
# ${1} - loop device
function wait_until_settled() {
  udevadm settle
  blockdev --flushbufs --rereadpt "${1}"
  until test -e "${1}p3"; do
    echo "${1}p3 doesn't exist yet..."
    sleep 1
  done
}

# Mount image helper (loop device + mount)
function mount_image() {
  LOOPDEV=$(losetup --find --partscan --show "${1:-${IMAGE}}")
  # Partscan is racy
  wait_until_settled "${LOOPDEV}"
  mount -o compress-force=zstd "${LOOPDEV}p3" "${MOUNT}"
  # Setup bind mount to package cache
  mount --bind "/var/cache/pacman/pkg" "${MOUNT}/var/cache/pacman/pkg"
}

# Unmount image helper (umount + detach loop device)
function unmount_image() {
  umount --recursive "${MOUNT}"
  losetup -d "${LOOPDEV}"
  LOOPDEV=""
}

# Compute SHA256, adjust owner to $SUDO_UID:$SUDO_UID and move to output/
function mv_to_output() {
  sha256sum "${1}" >"${1}.SHA256"
  if [ -n "${SUDO_UID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${1}"{,.SHA256}
  fi
  mv "${1}"{,.SHA256} "${OUTPUT}/"
}

# Helper function: create a new image from the "base" image
# ${1} - final file
# ${2} - pre
# ${3} - post
function create_image() {
  local tmp_image
  tmp_image="$(basename "$(mktemp -u)")"
  cp -a "${IMAGE}" "${tmp_image}"
  if [ -n "${DISK_SIZE}" ]; then
    truncate -s "${DISK_SIZE}" "${tmp_image}"
    sgdisk --align-end --delete 3 "${tmp_image}"
    sgdisk --align-end --move-second-header \
      --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
      "${tmp_image}"
  fi
  mount_image "${tmp_image}"
  if [ -n "${DISK_SIZE}" ]; then
    btrfs filesystem resize max "${MOUNT}"
  fi

  if [ 0 -lt "${#PACKAGES[@]}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/pacman -S --noconfirm "${PACKAGES[@]}"
  fi
  if [ 0 -lt "${#SERVICES[@]}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/systemctl enable "${SERVICES[@]}"
  fi
  "${2}"
  image_cleanup
  unmount_image
  "${3}" "${tmp_image}" "${1}"
  mv_to_output "${1}"
}

# List all available image options
function list_images() {
  echo "Available image options for IMAGES variable:"
  shopt -s nullglob
  for image in "${ORIG_PWD}/images/"!(base).sh; do
    local image_name
    image_name="$(basename "${image}" .sh)"
    echo "  - ${image_name}"
  done
  shopt -u nullglob
}

# Show help information
function show_help() {
  cat <<EOF
Usage: $0 [COMMAND] [BUILD_VERSION]

Commands:
  list              List all available image options for IMAGES variable
  help              Show this help message
  (none)            Build virtual machine images

Arguments:
  BUILD_VERSION     Optional build version (default: YYYYMMDD.0)

Environment Variables:
  IMAGES            Comma-separated list of image types to build
                    (default: all available images except base)

Examples:
  $0                           # Build all images with default version
  $0 20241201.1                # Build all images with specific version
  $0 list                      # List available image options
  $0 help                      # Show this help message
  IMAGES="cloud-image,basic" $0 # Build only cloud-image and basic
  IMAGES="yandex-cloud-image" $0 20241201.1 # Build yandex-cloud-image with version

Notes:
  - Requires root privileges for building images
  - The 'list' and 'help' commands work without root privileges
  - Available images are automatically detected from the images/ directory
  - The 'base' image cannot be selected as it's used internally

Package requirements:
  - arch-install-scripts
  - btrfs-progs
  - dosfstools
  - gptfdisk
  - jq
  - qemu-img

EOF
}

# ${1} - Optional build version. If not set, will generate a default based on date.
function main() {
  # Check for 'list' command
  if [ "${1:-}" = "list" ]; then
    list_images
    exit 0
  fi

  # Check for 'help' command
  if [ "${1:-}" = "help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
    exit 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    echo "root is required"
    exit 1
  fi
  init

  setup_disk
  bootstrap
  # shellcheck source=images/base.sh
  source "${ORIG_PWD}/images/base.sh"
  pre
  unmount_image

  local build_version
  if [ -z "${1:-}" ]; then
    build_version="$(date +%Y%m%d).0"
    echo "WARNING: BUILD_VERSION wasn't set!"
    echo "Falling back to $build_version"
  else
    build_version="${1}"
  fi

  # Determine which image scripts to use
  local image_scripts=()
  if [ -n "${IMAGES:-}" ]; then
    IFS=',' read -ra user_images <<< "$IMAGES"
    for img in "${user_images[@]}"; do
      if [[ "$img" == "base" ]]; then
        echo "Error: 'base' image cannot be selected for execution." >&2
        exit 2
      fi
      script_path="${ORIG_PWD}/images/${img}.sh"
      if [ ! -f "$script_path" ]; then
        echo "Error: Image script '$img' does not exist at $script_path" >&2
        exit 2
      fi
      image_scripts+=("$script_path")
    done
  else
    # Default: all images except base.sh
    shopt -s nullglob
    for image in "${ORIG_PWD}/images/"!(base).sh; do
      image_scripts+=("$image")
    done
    shopt -u nullglob
  fi

  for image in "${image_scripts[@]}"; do
    # shellcheck source=/dev/null
    source "${image}"
    create_image "${IMAGE_NAME}" pre post
  done
}
main "$@"
