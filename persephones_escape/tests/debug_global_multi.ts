/**
 * Captures global viewer screenshots at intervals to catch different phases.
 * Usage: npx tsx debug_global_multi.ts [ws://localhost:8080/global] [count] [intervalMs]
 */

import WebSocket from "ws";
import { createCanvas } from "canvas";
import { writeFileSync } from "fs";

const url = process.argv[2] ?? "ws://localhost:8080/global";
const totalShots = parseInt(process.argv[3] ?? "10");
const intervalMs = parseInt(process.argv[4] ?? "3000");
const CANVAS_W = 1280;
const CANVAS_H = 720;

const palette = [
  [0,0,0,255],[194,195,199,255],[255,241,232,255],[255,0,77,255],
  [255,119,168,255],[95,87,79,255],[171,82,54,255],[255,163,0,255],
  [255,236,39,255],[126,37,83,255],[0,135,81,255],[0,228,54,255],
  [29,43,83,255],[131,118,156,255],[41,173,255,255],[255,204,170,255]
];

const ZoomableFlag = 1, UiFlag = 2, MapLayerType = 0, UiZoom = 3;

interface Layer { id: number; type: number; flags: number; width: number; height: number; image: Uint8ClampedArray | null; }
interface Sprite { width: number; height: number; pixels: Uint8Array; }
interface Obj { id: number; x: number; y: number; z: number; layer: number; spriteId: number; }

const layers = new Map<number, Layer>();
const sprites = new Map<number, Sprite>();
const objects = new Map<number, Obj>();

function ensureLayer(id: number): Layer {
  let l = layers.get(id);
  if (!l) { l = { id, type: 0, flags: 0, width: 1, height: 1, image: null }; layers.set(id, l); }
  return l;
}

function parsePacket(buf: Buffer) {
  let i = 0;
  const u8 = () => buf[i++];
  const u16 = () => { const v = buf[i] | (buf[i+1] << 8); i += 2; return v; };
  const i16 = () => { let v = buf[i] | (buf[i+1] << 8); i += 2; if (v >= 0x8000) v -= 0x10000; return v; };
  while (i < buf.length) {
    const op = u8();
    switch (op) {
      case 0x01: { const id = u16(); const w = u16(); const h = u16(); const px = new Uint8Array(w*h); for (let j=0;j<w*h;j++) px[j]=u8(); sprites.set(id,{width:w,height:h,pixels:px}); break; }
      case 0x02: { const id=u16();const x=i16();const y=i16();const z=i16();const layer=u8();const spriteId=u16(); objects.set(id,{id,x,y,z,layer,spriteId}); break; }
      case 0x03: { objects.delete(u16()); break; }
      case 0x04: { sprites.clear(); objects.clear(); layers.clear(); break; }
      case 0x05: { const lid=u8();const w=u16();const h=u16(); const l=ensureLayer(lid); l.width=w;l.height=h;l.image=new Uint8ClampedArray(w*h*4); break; }
      case 0x06: { const lid=u8();const type=u8();const flags=u8(); const l=ensureLayer(lid); l.type=type;l.flags=flags; break; }
      default: return;
    }
  }
}

function putPixel(layer: Layer, x: number, y: number, color: number) {
  if (x<0||y<0||x>=layer.width||y>=layer.height||color===0||!layer.image) return;
  const rgba=palette[(color-1)&15], offset=(y*layer.width+x)*4;
  layer.image[offset]=rgba[0];layer.image[offset+1]=rgba[1];layer.image[offset+2]=rgba[2];layer.image[offset+3]=255;
}

function layerScreenPos(layer: Layer) {
  const uiZoom=(layer.flags&UiFlag)!==0?UiZoom:1;
  const width=layer.width*uiZoom, height=layer.height*uiZoom;
  if ((layer.flags&ZoomableFlag)!==0||layer.type===MapLayerType) {
    const scale=Math.min(CANVAS_W/layer.width,CANVAS_H/layer.height)*0.8;
    return {x:(CANVAS_W-layer.width*scale)/2,y:(CANVAS_H-layer.height*scale)/2,w:layer.width*scale,h:layer.height*scale};
  }
  switch(layer.type){
    case 1:return{x:0,y:0,w:width,h:height};
    case 2:return{x:CANVAS_W-width,y:0,w:width,h:height};
    case 3:return{x:CANVAS_W-width,y:CANVAS_H-height,w:width,h:height};
    case 4:return{x:0,y:CANVAS_H-height,w:width,h:height};
    case 5:return{x:(CANVAS_W-width)/2,y:0,w:width,h:height};
    case 6:return{x:CANVAS_W-width,y:(CANVAS_H-height)/2,w:width,h:height};
    case 7:return{x:0,y:(CANVAS_H-height)/2,w:width,h:height};
    case 8:return{x:(CANVAS_W-width)/2,y:CANVAS_H-height,w:width,h:height};
    default:return{x:0,y:0,w:width,h:height};
  }
}

function renderFrame(): Buffer {
  const canvas=createCanvas(CANVAS_W,CANVAS_H);
  const ctx=canvas.getContext("2d");
  ctx.imageSmoothingEnabled=false;
  ctx.fillStyle="black";ctx.fillRect(0,0,CANVAS_W,CANVAS_H);
  const orderedLayers=[...layers.values()].sort((a,b)=>a.type-b.type||a.id-b.id);
  for(const layer of orderedLayers){
    if(!layer.image)continue;
    const objs=[...objects.values()].filter(o=>o.layer===layer.id).sort((a,b)=>a.z-b.z||a.y-b.y||a.id-b.id);
    if((layer.flags&UiFlag)!==0&&objs.length===0)continue;
    layer.image.fill(0);
    for(const obj of objs){
      const sprite=sprites.get(obj.spriteId);if(!sprite)continue;
      for(let y=0;y<sprite.height;y++)for(let x=0;x<sprite.width;x++)putPixel(layer,obj.x+x,obj.y+y,sprite.pixels[y*sprite.width+x]);
    }
    const layerCanvas=createCanvas(layer.width,layer.height);
    const layerCtx=layerCanvas.getContext("2d");
    const imgData=layerCtx.createImageData(layer.width,layer.height);
    imgData.data.set(layer.image);layerCtx.putImageData(imgData,0,0);
    const pos=layerScreenPos(layer);
    ctx.drawImage(layerCanvas,pos.x,pos.y,pos.w,pos.h);
    if((layer.flags&UiFlag)!==0){ctx.strokeStyle="rgba(255,255,255,0.8)";ctx.lineWidth=1;ctx.strokeRect(Math.round(pos.x)+.5,Math.round(pos.y)+.5,Math.round(pos.w)-1,Math.round(pos.h)-1);}
  }
  return canvas.toBuffer("image/png");
}

const ws = new WebSocket(url, { perMessageDeflate: false });
let shotsTaken = 0;
let ready = false;

ws.on("message", (data: Buffer) => {
  parsePacket(data);
  if (!ready) { ready = true; scheduleShots(); }
});

function scheduleShots() {
  const take = () => {
    const path = `/tmp/global_${shotsTaken}.png`;
    writeFileSync(path, renderFrame());
    console.log(`[${shotsTaken}] ${path} (${layers.size} layers, ${objects.size} objects)`);
    shotsTaken++;
    if (shotsTaken >= totalShots) { ws.close(); process.exit(0); }
    else setTimeout(take, intervalMs);
  };
  setTimeout(take, 500);
}

ws.on("open", () => console.log("Connected"));
ws.on("error", (e) => { console.error("Error:", e.message); process.exit(1); });
ws.on("close", () => process.exit(0));
setTimeout(() => { console.error("Timeout"); process.exit(1); }, totalShots * intervalMs + 15000);
