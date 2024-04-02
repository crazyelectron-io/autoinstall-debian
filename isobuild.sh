#!/bin/bash
# This script runs all the commands to download the latest Debian ISO, insert a preseed file
# and recreate an unattended install ISO.
#Requires:
#	- 'xorriso' installed
#	- preseed.cfg
#   - GNU cpio installed (see README)
# It is based on the script from 
# NOTE: Tested with Debian 12 for AMD64 architecture only.

### Define our CPU architecture
ARCH=amd64

if [ $# -eq 1 ]; then
  PRESEED_FILE="preseed-$1.cfg"
  rm preseed.cfg 2> /dev/null
  cp "$PRESEED_FILE" preseed.cfg
else
  echo "Specify the target hostname on the command line"
  echo "  Example: $0 k3s-prod-m09"
  exit 1
fi

echo -n "Download the latest Debian $ARCH ISO..........."
BASE_URL=https://cdimage.debian.org/debian-cd/current/$ARCH/iso-cd
ISO=$( wget -qO - $BASE_URL/SHA512SUMS | grep netinst | grep -v mac | head -n 1 | awk '{ print $2 }' )
if [ ! -f "$ISO" ]; then
	wget "$BASE_URL/$ISO" -O "$ISO" > /dev/null
    if [ $? -eq 0 ] 
    then 
        echo "DONE ($ISO)" 
    else 
        echo "FAILED, ABORTING"
        exit 1
    fi
else
    echo -e "ALREADY DOWNLOADED ($ISO)"
fi

# Extract the Debian version from the downloaded ISO filename
VERSION=$(echo $ISO | awk -F"-" '{ print $2 }')
ISO_LABEL="Debian $VERSION $ARCH n"

echo -n "Setup the working directory...................."
WORKDIR=temp-iso
if [ -d "$WORKDIR" ]; then
    chmod -R +w $WORKDIR
    rm -rf $WORKDIR
fi
mkdir $WORKDIR
if [ $? -eq 0 ] 
then 
  echo "DONE" 
else 
  echo "FAILED, ABORTING"
  exit 1
fi

# Construct the name of new ISO file
ISO_SRC=$( find . -name '*.iso' | grep -v preseed | head -n 1 )
ISO_PREFIX=$( echo "$ISO_SRC" | sed 's/.iso//' )
ISO_TARGET="$ISO_PREFIX-preseed-$1.iso"

echo -n "Extract all files from the ISO................."
xorriso -osirrox on -indev "$ISO_SRC" -extract / $WORKDIR/  > /dev/null 2> /dev/null
if [ $? -eq 0 ] 
then 
  echo "DONE" 
else 
  echo "FAILED, ABORTING"
  exit 1
fi

echo -n "Add the preseed file to initrd..............."
chmod -R +w $WORKDIR/install.amd/
gunzip -q $WORKDIR/install.amd/initrd.gz
if [ $? -eq 0 ] 
then 
  echo -n "." 
else 
  echo "FAILED, ABORRTING"
  exit 1
fi
echo preseed.cfg | cpio -H newc -o -A --quiet -F $WORKDIR/install.amd/initrd
if [ $? -eq 0 ] 
then 
  echo -n "." 
else 
  echo "FAILED, ABORRTING"
  exit 1
fi
gzip -q $WORKDIR/install.amd/initrd
if [ $? -eq 0 ] 
then 
  echo "DONE" 
else 
  echo "FAILED, ABORRTING"
  exit 1
fi
chmod -R -w $WORKDIR/install.amd/

echo -n "Extract the boot record for BIOS boot mode.."
MBR=isohdpfx.bin
dd if="$ISO_SRC" bs=1 count=432 of=$WORKDIR/$MBR status=none
if [ $? -eq 0 ]
then 
  echo "...DONE" 
else 
  echo "...FAILED, ABORTING"
  exit 1
fi

echo -n "Modify the boot menu for ISOLINUX (BIOS)...."
sed --quiet '$d' "$WORKDIR/isolinux/isolinux.cfg"
if [ $? -eq 0 ]
then 
  echo "...DONE" 
else 
  echo "...FAILED, ABORTING"
  exit 1
fi

echo -n "Modify the boot menu for GRUB (UEFI)..........."
chmod -R +w $WORKDIR/boot/grub/
sed -i "/insmod play/a\set timeout_style=hidden\\nset timeout=0\\nset default=1" $WORKDIR/boot/grub/grub.cfg
if [ $? -eq 0 ]
then 
  echo "DONE" 
else 
  echo "FAILED, ABORTING"
  exit 1
fi
chmod -R -w $WORKDIR/boot/grub/

echo -n "Regenerate the MD5 checksums..................."
pushd "$PWD" > /dev/null
cd $WORKDIR
chmod a+w md5sum.txt
find -L . -type f -exec md5sum {} + > md5sum.txt ;
if [ $? -eq 0 ]
then 
  echo "DONE" 
else 
  echo "FAILED, ABORTING"
  exit 1
fi
chmod a-w md5sum.txt
popd > /dev/null

echo -n "Build the preseeded ISO........................"
rm $ISO_TARGET 2> /dev/null
xorriso -as mkisofs \
    -r -V "$ISO_LABEL" \
    -o "$ISO_TARGET" \
    -isohybrid-mbr $WORKDIR/$MBR \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 -boot-info-table -no-emul-boot \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \
     $WORKDIR > /dev/null 2> /dev/null
if [ $? -eq 0 ]
then 
  echo "DONE" 
else 
  echo "FAILED, ABORTING"
  exit 1
fi

echo -n "Cleanup the temporary directory................"
chmod -R +w $WORKDIR
rm -rf $WORKDIR
rm -f preseed.cfg
if [ $? -eq 0 ]
then 
  echo "DONE" 
else 
  echo "FAILED, ABORTING"
  exit 1
fi

echo "READY. Updated ISO created: $ISO_TARGET"
# Optionally remove the original ISO
#rm $SRC_ISO