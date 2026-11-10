# usage: mkinitramfs.py out.cpio.gz init busybox   -- minimal newc initramfs: /init, /bin/busybox + applet symlinks, mountpoints, /dev/console
import sys,gzip,os
init=open(sys.argv[2],'rb').read(); bb=open(sys.argv[3],'rb').read(); ents=[]; ino=[1]
def add(name,mode,body=b'',rdev=(0,0)):
    ino[0]+=1; nb=name.encode()+b'\0'
    h=b'070701'+b''.join(b'%08X'%v for v in (ino[0],mode,0,0,1,0,len(body),0,0,rdev[0],rdev[1],len(nb),0))
    p=lambda b:b+b'\0'*((-len(b))%4); ents.append(p(h+nb)+p(body))
for d in ('bin','proc','sys','dev','tmp','mnt','etc','sys/fs','sys/fs/pstore'): add(d,0o040755)
add('init',0o100755,init); add('bin/busybox',0o100755,bb)
for a in 'sh ls cat mount umount dmesg dd hexdump od mkdir ps ip ifconfig sleep echo reboot poweroff sync lsmod head tail grep find df free uname cp mv rm chmod insmod modprobe devmem vi tr'.split(): add('bin/'+a,0o120777,b'busybox')
add('dev/console',0o020600,rdev=(5,1)); add('dev/null',0o020666,rdev=(1,3))
ents.append(b'070701'+b''.join(b'%08X'%v for v in (0,0,0,0,1,0,0,0,0,0,0,11,0))+b'TRAILER!!!\0'+b'\0'*((-(110+11))%4))
open(sys.argv[1],'wb').write(gzip.compress(b''.join(ents),9)); print('ok')
