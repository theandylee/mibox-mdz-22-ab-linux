# usage: mkimg_new.py stock.img kernel.gz ramdisk.gz mibox.dtb out.img
# Builds a boot image v2 from the stock one: replaces kernel + ramdisk, puts the given DTB into all three slots of the
# stock Amlogic DTB container (used for both `second` and `dtb`), keeps header/cmdline/recovery_dtbo, pads to stock size.
import sys,struct,hashlib
img=open(sys.argv[1],'rb').read(); K=open(sys.argv[2],'rb').read(); R=open(sys.argv[3],'rb').read(); dtb=open(sys.argv[4],'rb').read()
ks,ka,rs,ra,ss,sa,ta,ps,hv,osv=struct.unpack_from('<10I',img,8)
dsz,doff,hsz,dtbsz,dtba=struct.unpack_from('<IQIIQ',img,1632)
pg=lambda n:(n+ps-1)//ps*ps
o=ps+pg(ks)+pg(rs); Sd=img[o:o+ss]; o+=pg(ss); D=img[o:o+dsz]; o+=pg(dsz); T=img[o:o+dtbsz]
assert Sd==T and Sd[:4]==b'AML_'
c=bytearray(Sd)
for i in range(3):
    off,sz=struct.unpack_from('<II',Sd,12+i*56+48); assert len(dtb)<=sz
    c[off:off+sz]=dtb+b'\0'*(sz-len(dtb))
c=bytes(c)
h=bytearray(img[:ps]); h[8:12]=struct.pack('<I',len(K)); h[16:20]=struct.pack('<I',len(R)); h[24:28]=struct.pack('<I',len(c))
h[1636:1644]=struct.pack('<Q',ps+pg(len(K))+pg(len(R))+pg(len(c)))
sha=hashlib.sha1()
for b in (K,R,c,D,c): sha.update(b); sha.update(struct.pack('<I',len(b)))
h[576:608]=sha.digest()+b'\0'*12
pad=lambda b:b+b'\0'*(pg(len(b))-len(b))
out=bytes(h)+pad(K)+pad(R)+pad(c)+pad(D)+pad(c)
assert len(out)<=len(img),(len(out),len(img)); out+=b'\0'*(len(img)-len(out))
open(sys.argv[5],'wb').write(out); print('built',len(out),'kernel',len(K),'ramdisk',len(R))
