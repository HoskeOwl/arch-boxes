#!/bin/bash
# shellcheck disable=SC2034,SC2154
IMAGE_NAME="Arch-Linux-x86_64-yandex-cloudimg-${build_version}.qcow2"
DISK_SIZE=""
# The following modules require additional packages:
# - growpart[1] requires the cloud-guest-utils package
# - disk setup[2] requires the sgdisk package
# [1] https://cloudinit.readthedocs.io/en/latest/reference/modules.html#growpart
# [2] https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup
PACKAGES=(cloud-init cloud-guest-utils gptfdisk)
SERVICES=(cloud-init-main.service cloud-init-local.service cloud-init-network.service cloud-config.service cloud-final.service)

function pre() {
  # echo "DEBUG with root password"
  # export ROOT_PASSWORD=$(gpg --gen-random --armor 1 15)
  # echo "password: '${ROOT_PASSWORD}'"
  # arch-chroot "${MOUNT}" bash -c "echo '${ROOT_PASSWORD}' | passwd --stdin root"

  mkdir -p "${MOUNT}/etc/cloud/cloud.cfg.d"
  echo -e "datasource_list: [ Ec2 ]\ndatasource:\n  Ec2:\n    strict_id: false" > "${MOUNT}/etc/cloud/cloud.cfg.d/90_datasource.cfg"
  # because of breack changes in cloud-init 25.1.4
  # https://cloudinit.readthedocs.io/en/latest/reference/breaking_changes.html
  echo -e "policy: search,found=all,maybe=all,notfound=disabled\n" > "${MOUNT}/etc/cloud/ds-identify.cfg"


  sed -Ei 's/^(GRUB_CMDLINE_LINUX_DEFAULT=.*)"$/\1 console=tty0 console=ttyS0,115200"/' "${MOUNT}/etc/default/grub"
  echo 'GRUB_TERMINAL="serial console"' >>"${MOUNT}/etc/default/grub"
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${MOUNT}/etc/default/grub"
  arch-chroot "${MOUNT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
}

function post() {
  qemu-img convert -c -f raw -O qcow2 "${1}" "${2}"
  rm "${1}"
}
