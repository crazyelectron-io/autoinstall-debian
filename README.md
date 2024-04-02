# Setup Debian server

Debian has been my Linux Distribution of choice since version 6.
Currenty I am running Debian 12 on just about all physical and virtual servers.

Some of my servers are 1U Supermicro servers.
They are very low power (15W TDP) 4-core Atom C3558 systems with 64GB of ECC DDR-4 DRAM and a Samsung 980 Pro NVMe SSD, which serve as Kubernetes master nodes and management servers.
The other servers, which are used as worker nodes in the Kubernetes cluster are equiped with more cores (10 each), memory (128 GB) and SSD drives (4x 8TB).

## Unattended installation

Because these [Supermicro A2SDI-4C-HLN4F](https://www.supermicro.com/en/products/motherboard/a2sdi-4c-hln4f) servers have out-of-band control, the bare metal install can be performed completely remote by virtually plugging in the ISO image using the Supermicro IPMIViewer and the mounted ISO will presents itself as a bootable (UEFI) device on the server.
For most of the other servcers I have to resort to a IP-KVM switch from ATEN.
For the boot image a customized Debian netboot ISO with a preseed file is used to make it a fully unattended install for the OS.
Since the Debian Installer does not support installation and configuration of additional NIC's, nor NIC bonding, those configuration settings must be done after this initial bare metal installation.

### Custom ISO with preseed

Debian uses a so called _preseed file_ to support unattended installations.
It is nothing more than a set of answers to the questions that the installer might ask, stored in a file called `preseed.cfg`.
Most of the `preseed.cfg` content is straightforward, except for handling the partitioning, especially with multiple disks attached.
The included preseed file for the management server has some tricks to ignore any mounted virtual USB boot disk and select the first - in my config NVMe - SSD.

> It is strongly advised to disconnect any other disk during the initial OS install, as well as extra network connections to be setup later.

The Debian reseed file must be added to `initrd` in the ISO and also the ISOLINUX/GRUB boot parameters need some adjustment to get rid of any boot menu prompt in either BIOS or UEFI boot mode.

A few tools are needed to perform the required magic on the Debian netboot ISO.
On Debian, we can just install `xorriso` but MacOS needs a little more attention by installing some additional GNU tools because the BSD versions are not quite compatible or lack some needed features.

#### Prepare tools on Debian

  ```bash
  wget -O $HOME/debian.iso https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.1.0-amd64-netinst.iso
  sudo apt install xorriso -y
  ```

#### Prepare tools on MacOS Sonoma

  ```bash
  wget -O $HOME/debian.iso https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.1.0-amd64-netinst.iso
  brew install xorriso
  # Darwin/MacOS version of `cpio` does not support the `append` option.
  # We have to build the GNU version from source.
  curl -O http://ftp.gnu.org/gnu/cpio/cpio-2.14.tar.gz
  tar xzvf cpio-2.14.tar.gz
  rm cpio-2.14.tar.gz
  cd cpio-2.14
  ./configure ac_cv_prog_cc_stdc=no
  make
  spctl --add src/cpio
  sudo cp src/cpio /usr/local/bin
  rm -rf cpio-2.14
  # Also BSD `sed` is not GNU compatible, so we must install GNU `sed`.
  brew install gnu-sed
  ln -s /opt/homebrew/bin/gsed /opt/homebrew/bin/sed
  # Make sure to start a new terminal session to pick up the right `cpio` and `sed`.
  exit
  ```

### Using a script to modify the ISO

A simple script is included to run all commands automatically, called `isobuild.sh`.
Make sure it is executable (`chmod +x isobuild.sh`).
A preseed filename can be specified on the commandline, otherwise the default filename `preseed.cfg` is used.

For clarity and documentation purposed, the individual steps and commands are described in the next paragraphs but they are done by simply running the script.

#### 1. Download and unpack the ISO

Download the latest Debian image - I always use the _amd64_ version from the [official Debian mirror](https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/), which is currently version 12.1.0.
To modify the ISO image, its content must be extracted and afterwards recreated with the required changes.
This can be done with `xorriso`:

```bash
mkdir temp-iso
xorriso -osirrox on -indev /debian-12.1.0-amd64-netinst.iso -extract / temp-iso/
```

#### 2. Add the preseed file to initrd

To ensure the installation is unattended from the start, the preseed file should be included in `initrd` by unpacking it, adding the file and repacking it again.

```shell
chmod -R +w temp-iso/install.amd/
gunzip temp-iso/install.amd/initrd.gz
echo preseed.cfg | cpio -H newc -o -A -F temp-iso/install.amd/initrd
gzip temp-iso/install.amd/initrd
chmod -R -w temp-iso/install.amd/
```

#### 3. Add non-free firmware files

```bash
wget http://ftp.fr.debian.org/debian/pool/non-free/f/firmware-nonfree/xxxxx #TODO
cp xxxx temp-iso/firmware
```

#### 4. Update the bootloader

Before we can generate the new ISO, we need to extract the first 432 bytes from the ISO to get the MBR content.

```bash
dd if="$HOME/debian-12.1.0-amd64-netinst.iso" bs=1 count=432 of=temp-iso/isohdpfx.bin
```

The ISOLINUX boot loader uses the legacy Master Boot Record which makes it compatible with BIOS boot mode.
We have to edit the `isolinux/isolinux.cfg` file and delete the line last line (`default vesamenu.c32`) to avoid the Debian installation menu in BIOS boot mode.

```bash
sed '$d' temp-iso/isolinux/isolinux/cfg
```

For UEFI boot, which I use, the `grub` menu in `boot/grub/grub.cfg` must be modified by adding 3 lines that supress the Debian installation menu prompt.

```shell
chmod -R +w temp-iso/boot/grub/
sed -i "/insmod play/a\set timeout_style=hidden\\nset timeout=0\\nset default=1" temp-iso/boot/grub/grub.cfg
chmod -R -w temp-iso/boot/grub/
```

#### 5. Regenerate the MD5 checksum

Since we made changes to the files, the MD5 checksum is no longer valid and must be recalculated.

```bash
pushd $PWD
cd $WORKDIR
chmod a+w md5sum.txt
find -L . -type f -exec md5sum {} + > md5sum.txt ;
chmod a-w md5sum.txt
popd
```

#### 6. Create the updated ISO

To recreate the ISO we run a modified version of the command used to create the original ISO.
The original build command can be found in `./iso/.disk/mkisofs`.

```shell
xorriso -as mkisofs \
    -r -V 'Debian 12.1.0 amd64 n' \
    -o debian-12.1.0-amd64-netinst-preseeded.iso \
    -isohybrid-mbr temp-iso/isohdpfx.bin \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 -boot-info-table -no-emul-boot \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \
     temp-iso
```

## Install the Debian base system

Mount this new ISO as Virtual Storage to the server using the Supermicro IPMI Java console and boot from that device.
Since preseed does not support multiple NICs, we have to install the system with a single NIC (eno1) and configure the rest later.
The unattended install will kick in and setup Debian.
At the end of the installer process, a few additional commands are executed to prepare for the network changes and add the SSH key for the primary management user to connect via SSH without password.

> Note that the `root` user is not activated in this setup, but the regular user has `sudo` rights.

Login to the server using the IPMI console to reconfigure the network manually.
The rest of the configuration will use files from this GitHub repository that can be pulled to the server because `git` is already installed during the preseed phase.

### Encrypt configuration file

This repo has all the secrets in one YAML file `./inventory/group_vars/all.sops.yaml` and the very first time we create it, it must be encrypted manually once with SOPS:

```bash
sops -e -i ./inventory/group_vars/all.sops.yaml
```

After that, the VS Code extension `signageos/vscode-sops` is used to automattically decrypt and reencrypt the file whenever it is edited (and Ansible has a plugin to decrypt variables when loaded).
For this to work `sops` and `age` must be installed and a key generated and stored in `~/.sops/key,txt`.
In addition, a SOPS configuration file is created in the `./inventory` directory which contains the `age` public key:

```yaml
  # file: ./inventory/.sops.yaml
  creation_rules:
    - path_regex: .*vars/.*
      age: "age109fzapgarv59gpxu5zqmwgn8j7hxmfz8dhrz9lrqvky046jxafmse38kvj"
```

## Configure Debian with Ansible

The automated installation is parameterized with a set of variables defined in the inventory directory.
Check and agjust as needed before running the deployment playbook.

Ansible is already installed with the Debian Installer as specified in the Preseed file so we can use the playbook included in the downloaded repository to do the rest of the setup by running the following commands to install all required dependencies:

```bash
ansible-galaxy collection install community.general
ansible-galaxy install -r roles/requirements.yaml --force
```

> `--force` is optional and overwrites existing downloads.

Next, all needed packages and configuration updates can by applied running `ansible-playbook debian-deploy.yaml -i ./inventory -u <ANSIBLE_USER>`.

```yaml
  roles:
    - local/sops
    - debian-base
    - docker
      when: install_docker | bool
```

As can be seen from the Ansible roles in the playbook, it configures Debian and deploys additional packages (including their config) on the freshly installed servers.
The list of Debian packages to be installed can be adjusted by changing the role variable `debian_packages`.

This is also the phase where the network is reconfigured for NIC bonding (LACP) of two sets of NIC's (the Supermicro systems have 4 NIC's).
The `/etc/network/interfaces` file has the new configuration and because the servers are rebooted, they expect a switch configuration with port aggregation.
Test de bonds by checking we the server can be pinged and also by removing one of the cables and verifying the connection again.

> DHCP with reserved addresses could also be used, but this setup uses fixed IP addresses based on the fact that it might be the very first server to setup in the network (even while still using the standard ISP router/firewall setup as starting point).
