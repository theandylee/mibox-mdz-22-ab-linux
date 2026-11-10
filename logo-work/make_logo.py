# usage: make_logo.py stock_logo.img wallpaper.png out_logo.img [preview.png]
# Replaces the `bootup` item of an Amlogic AML_RES! logo package with the wallpaper (1920x1080, 24-bit BMP, gzip).
# All other items stay byte-identical; the new item is appended after the last one, table/size/CRC are updated.
import sys,struct,gzip,io,zlib
from PIL import Image
d=bytearray(open(sys.argv[1],'rb').read()); n=len(d)
assert d[8:16]==b'AML_RES!' and struct.unpack_from('<I',d,0x14)[0]==9
size=struct.unpack_from('<I',d,0x10)[0]
assert (zlib.crc32(bytes(d[4:size]))^0xffffffff)==struct.unpack_from('<I',d,0)[0], 'stock CRC check failed'
ent=None
for i in range(9):
    o=0x40+i*0x40
    if d[o+32:o+64].rstrip(b'\0')==b'bootup': ent=o
assert ent
im=Image.open(sys.argv[2]).convert('RGBA'); W,H=1920,1080
bg=Image.new('RGB',(W,H))
px=bg.load()
for y in range(H):                       # dark vertical gradient
    c=int(10+22*y/H); 
    for x in range(W): px[x,y]=(c//2,c,c+10)
th=820; tw=int(im.width*th/im.height); t=im.resize((tw,th),Image.LANCZOS)
bg.paste(t,((W-tw)//2,(H-th)//2-20),t)
if len(sys.argv)>4: bg.save(sys.argv[4])
b=io.BytesIO(); bg.save(b,'BMP'); bmp=b.getvalue(); assert bmp[:2]==b'BM' and struct.unpack_from('<H',bmp,28)[0]==24
gz=gzip.compress(bmp,9)
off=(size+15)&~15; end=off+len(gz); newsize=(end+15)&~15
assert newsize<=n-4096,(newsize,n)
d[size:off]=b'\0'*(off-size) if off>size else b''
d[off:off+len(gz)]=gz
struct.pack_into('<II',d,ent+8,len(gz),off)
struct.pack_into('<I',d,0x10,newsize)
struct.pack_into('<I',d,0,(zlib.crc32(bytes(d[4:newsize]))^0xffffffff)&0xffffffff)
assert len(d)==n
open(sys.argv[3],'wb').write(d); print('bootup gz %d bytes at 0x%x, package size 0x%x, file %d'%(len(gz),off,newsize,len(d)))
