// Decodes a sprite packet with the browser codec (client/spritecodec.js
// plus client/snappyjs.min.js) under node and compares every sprite
// against the RGBA bytes the Nim encoder started from.
//
//   node tests/spritecodec_check.js packet.bin expected.bin
//
// expected.bin holds, per sprite in packet order: u16 sprite id,
// u32 pixel byte count, then that many RGBA bytes.
"use strict";
const fs=require("fs");
const path=require("path");
const clientDir=path.join(__dirname,"..","client");
// snappyjs.min.js registers itself on `window`; give node one.
if(typeof globalThis.window==="undefined")globalThis.window=globalThis;
require(path.join(clientDir,"snappyjs.min.js"));
require(path.join(clientDir,"spritecodec.js"));
const SpriteCodec=globalThis.SpriteCodec;
if(!globalThis.SnappyJS)throw new Error("snappyjs did not register on the global object");

const packet=new Uint8Array(fs.readFileSync(process.argv[2]));
const expected=new Uint8Array(fs.readFileSync(process.argv[3]));
const textDecoder=new TextDecoder("utf-8");

function readU16(bytes,offset){return bytes[offset]|(bytes[offset+1]<<8)}
function readU32(bytes,offset){return (bytes[offset]|(bytes[offset+1]<<8)|(bytes[offset+2]<<16)|(bytes[offset+3]*0x1000000))>>>0}

const sprites=new Map();
const order=[];
let offset=0;
while(offset<packet.length){
  const type=packet[offset++];
  if(type===0x01){
    const id=readU16(packet,offset);
    const width=readU16(packet,offset+2);
    const height=readU16(packet,offset+4);
    const length=readU32(packet,offset+6);
    offset+=10;
    const payload=packet.subarray(offset,offset+length);
    offset+=length;
    const labelLength=readU16(packet,offset);
    offset+=2+labelLength;
    const decoded=SpriteCodec.decodeSprite(0x00,payload,width,height,null);
    sprites.set(id,{width,height,pixels:decoded.pixels,indices:null,palette:null});
    order.push(id);
  }else if(type===0x08){
    const encoded=SpriteCodec.readEncodedSprite(packet,offset,textDecoder);
    if(!encoded)throw new Error("truncated encoded sprite at "+offset);
    const decoded=SpriteCodec.decodeSprite(
      encoded.encoding,encoded.payload,encoded.width,encoded.height,
      sourceId=>sprites.get(sourceId)
    );
    sprites.set(encoded.id,{
      width:encoded.width,height:encoded.height,
      pixels:decoded.pixels,indices:decoded.indices,palette:decoded.palette,
      label:encoded.label,encoding:encoded.encoding
    });
    order.push(encoded.id);
    offset=encoded.offset;
  }else{
    throw new Error("unexpected message type "+type+" at "+(offset-1));
  }
}

let cursor=0,checked=0,failed=0;
for(const id of order){
  const expectedId=readU16(expected,cursor);
  const length=readU32(expected,cursor+2);
  cursor+=6;
  const want=expected.subarray(cursor,cursor+length);
  cursor+=length;
  const sprite=sprites.get(id);
  let ok=expectedId===id&&sprite&&sprite.pixels.length===length;
  if(ok){
    for(let i=0;i<length;i++){
      if(sprite.pixels[i]!==want[i]){ok=false;break}
    }
  }
  checked++;
  if(!ok){
    failed++;
    console.log("sprite "+id+" MISMATCH ("+(sprite?sprite.width+"x"+sprite.height+" encoding "+sprite.encoding:"missing")+")");
  }else{
    console.log("sprite "+id+" ok "+sprite.width+"x"+sprite.height+" encoding "+sprite.encoding+" "+(sprite.label||""));
  }
}
if(cursor!==expected.length){
  console.log("expected data has trailing bytes");
  failed++;
}
console.log(checked+" sprites checked, "+failed+" failed");
process.exit(failed===0?0:1);
