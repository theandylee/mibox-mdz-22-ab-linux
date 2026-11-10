#!/usr/bin/env python3
# Load signed Android-12-OTA bl2+tpl into RAM over USB burn mode (GXL secure boot). Never writes flash.
import sys, os, time
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, 'pyaml'))
from pyamlboot import pyamlboot
F = os.path.join(HERE, 'pyaml', 'files')
OTA = os.path.join(HERE, '..', 'ota-bootloader.img')
DDR_LOAD, BL2_PARAMS, UBOOT_LOAD = 0xd9000000, 0xd900c000, 0x200c000
img = open(OTA, 'rb').read(); assert len(img) == 1442304
bl2, tpl = img[:49152], img[49152:]
ddr = open(os.path.join(F, 'usbbl2runpara_ddrinit.bin'), 'rb').read()
fip = open(os.path.join(F, 'usbbl2runpara_runfipimg.bin'), 'rb').read()
dev = pyamlboot.AmlogicSoC(timeout=20)
def ident():
    s = dev.identify(); print('ROM %d.%d stage %d.%d' % tuple(ord(c) for c in s[:4])); return ord(s[3])
ident()
dev.writeMemory(DDR_LOAD, bl2)
dev.writeLargeMemory(BL2_PARAMS, ddr, 32, False)
dev.run(DDR_LOAD); time.sleep(1)
st = ident()
if st == 8: dev.run(BL2_PARAMS); time.sleep(1)
dev.writeLargeMemory(DDR_LOAD, bl2, 64, False)
dev.writeLargeMemory(BL2_PARAMS, fip, 48, False)
dev.writeLargeMemory(UBOOT_LOAD, tpl, 64, True)
dev.run(BL2_PARAMS if st == 8 else DDR_LOAD)
print('U-Boot started')
