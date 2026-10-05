// Genera los íconos PNG de la PWA (sin dependencias): node tools/icons.js
const fs=require("fs"),zlib=require("zlib"),path=require("path");
const BG=[0xc2,0x41,0x0c],FG=[0xff,0xff,0xff];
function png(size,maskable){const px=Buffer.alloc(size*size*4),s=size/512;
 // carrito simple: canasto + manija + dos ruedas, centrado en la zona segura (80%)
 const inRR=(x,y,x0,y0,x1,y1,r)=>{if(x<x0||x>x1||y<y0||y>y1)return false;const cx=Math.min(Math.max(x,x0+r),x1-r),cy=Math.min(Math.max(y,y0+r),y1-r);return(x-cx)**2+(y-cy)**2<=r*r};
 const circ=(x,y,cx,cy,r)=>(x-cx)**2+(y-cy)**2<=r*r;
 for(let j=0;j<size;j++)for(let i=0;i<size;i++){const x=i/s+.5/s,y=j/s+.5/s;let a=255,c=BG;
  if(!maskable&&!inRR(x,y,0,0,512,512,96))a=0;   // ícono normal con esquinas redondeadas; maskable a sangre
  const body=inRR(x,y,150,190,390,330,22),handle=inRR(x,y,96,150,190,182,14)||inRR(x,y,150,150,182,260,14),wheel=circ(x,y,200,380,30)||circ(x,y,340,380,30);
  if(a&&(body||handle||wheel))c=FG;const o=(j*size+i)*4;px[o]=c[0];px[o+1]=c[1];px[o+2]=c[2];px[o+3]=a}
 const raw=Buffer.alloc((size*4+1)*size);for(let j=0;j<size;j++){raw[j*(size*4+1)]=0;px.copy(raw,j*(size*4+1)+1,j*size*4,(j+1)*size*4)}
 const crc=b=>{let c,t=[];for(let n=0;n<256;n++){c=n;for(let k=0;k<8;k++)c=c&1?0xedb88320^(c>>>1):c>>>1;t[n]=c>>>0}let r=-1;for(const x of b)r=(r>>>8)^t[(r^x)&255];return(r^-1)>>>0};
 const chunk=(ty,d)=>{const l=Buffer.alloc(4);l.writeUInt32BE(d.length);const td=Buffer.concat([Buffer.from(ty),d]),c=Buffer.alloc(4);c.writeUInt32BE(crc(td));return Buffer.concat([l,td,c])};
 const ih=Buffer.alloc(13);ih.writeUInt32BE(size,0);ih.writeUInt32BE(size,4);ih[8]=8;ih[9]=6;
 return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk("IHDR",ih),chunk("IDAT",zlib.deflateSync(raw,{level:9})),chunk("IEND",Buffer.alloc(0))])}
const out=path.join(__dirname,"..","icons");fs.mkdirSync(out,{recursive:true});
for(const[f,sz,m]of[["icon-192.png",192,false],["icon-512.png",512,false],["maskable-192.png",192,true],["maskable-512.png",512,true]])fs.writeFileSync(path.join(out,f),png(sz,m));
console.log("íconos generados en icons/");
