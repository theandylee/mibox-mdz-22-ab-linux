#!/bin/bash
# Installs the built modules into kernel/modroot (stripped, depmod'ed) for stick-setup/install-modules.sh
set -e
P="$(cd "$(dirname "$0")/.." && pwd)"; K=$P/kernel/linux-6.12.114
rm -rf $P/kernel/modroot; cd $K
make -j12 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH=$P/kernel/modroot INSTALL_MOD_STRIP=1 DEPMOD=true
rm -f $P/kernel/modroot/lib/modules/*/build $P/kernel/modroot/lib/modules/*/source
depmod -b $P/kernel/modroot 6.12.114-ophub
du -sh $P/kernel/modroot; find $P/kernel/modroot -name '*.ko*' | wc -l
