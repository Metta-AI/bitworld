// Sprite v1 Define Encoded Sprite (0x08) decoder for browser clients.
//
// Exposes SpriteCodec.decodeSprite(encoding, payload, width, height,
// lookup), which returns {pixels, indices, palette}: straight RGBA
// pixels (Uint8Array of width*height*4), plus the index plane and RGBA
// palette for indexed and palette-swap sprites so a later palette swap
// can reuse them. `lookup(spriteId)` must return the previously decoded
// sprite object ({indices, width, height}) for palette swaps.
//
// Encodings:
//   0x00 rgba-snappy   Snappy stream of raw RGBA (needs window.SnappyJS)
//   0x01 rgba-deflate  zlib stream of raw RGBA
//   0x02 indexed       u8 count-1, count*4 palette bytes, zlib(index bytes)
//   0x03 palette-swap  u16 source sprite id, u8 count-1, count*4 palette
//
// SpriteCodec.inflate is a small RFC 1950/1951 decoder (stored, fixed,
// and dynamic Huffman blocks) written against a known output length,
// so browser clients decode synchronously inside the packet parser.
(function(root){
"use strict";

const LENGTH_BASE=[3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
const LENGTH_EXTRA=[0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
const DIST_BASE=[1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
const DIST_EXTRA=[0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
const CODE_LENGTH_ORDER=[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];

function buildHuffman(lengths,count){
  // Canonical Huffman table in the style of zlib's puff.c: counts per
  // code length and symbols ordered by (length, value).
  const lengthCount=new Uint16Array(16);
  for(let i=0;i<count;i++)lengthCount[lengths[i]]++;
  lengthCount[0]=0;
  const offsets=new Uint16Array(16);
  for(let len=1;len<16;len++)offsets[len]=offsets[len-1]+lengthCount[len-1];
  const symbols=new Uint16Array(count);
  for(let i=0;i<count;i++){
    if(lengths[i])symbols[offsets[lengths[i]]++]=i;
  }
  return {lengthCount,symbols};
}

let fixedLiteral=null,fixedDistance=null;
function fixedTables(){
  if(fixedLiteral)return;
  const lengths=new Uint8Array(288);
  let i=0;
  for(;i<144;i++)lengths[i]=8;
  for(;i<256;i++)lengths[i]=9;
  for(;i<280;i++)lengths[i]=7;
  for(;i<288;i++)lengths[i]=8;
  fixedLiteral=buildHuffman(lengths,288);
  const distances=new Uint8Array(30).fill(5);
  fixedDistance=buildHuffman(distances,30);
}

function inflate(input,expectedLength){
  // Decodes a zlib (RFC 1950) or raw deflate (RFC 1951) stream into a
  // Uint8Array of exactly expectedLength bytes.
  const src=input instanceof Uint8Array?input:new Uint8Array(input);
  let pos=0;
  if(src.length>=2&&(src[0]&0x0f)===8&&(((src[0]<<8)|src[1])%31)===0){
    if(src[1]&0x20)throw new Error("zlib preset dictionary not supported");
    pos=2;
  }
  const out=new Uint8Array(expectedLength);
  let outPos=0;
  let bitBuffer=0,bitCount=0;

  function bits(need){
    let value=bitBuffer;
    while(bitCount<need){
      if(pos>=src.length)throw new Error("deflate stream truncated");
      value|=src[pos++]<<bitCount;
      bitCount+=8;
    }
    bitBuffer=value>>>need;
    bitCount-=need;
    return value&((1<<need)-1);
  }

  function decodeSymbol(table){
    let code=0,first=0,index=0;
    for(let len=1;len<16;len++){
      code|=bits(1);
      const count=table.lengthCount[len];
      if(code-count<first)return table.symbols[index+(code-first)];
      index+=count;
      first+=count;
      first<<=1;
      code<<=1;
    }
    throw new Error("bad huffman code");
  }

  function inflateBlock(literal,distance){
    for(;;){
      let symbol=decodeSymbol(literal);
      if(symbol<256){
        if(outPos>=expectedLength)throw new Error("deflate output too long");
        out[outPos++]=symbol;
      }else if(symbol===256){
        return;
      }else{
        symbol-=257;
        if(symbol>=29)throw new Error("bad length code");
        const length=LENGTH_BASE[symbol]+bits(LENGTH_EXTRA[symbol]);
        const distSymbol=decodeSymbol(distance);
        if(distSymbol>=30)throw new Error("bad distance code");
        const dist=DIST_BASE[distSymbol]+bits(DIST_EXTRA[distSymbol]);
        if(dist>outPos)throw new Error("deflate distance too far back");
        if(outPos+length>expectedLength)throw new Error("deflate output too long");
        let from=outPos-dist;
        for(let i=0;i<length;i++)out[outPos++]=out[from++];
      }
    }
  }

  let last=0;
  do{
    last=bits(1);
    const type=bits(2);
    if(type===0){
      bitBuffer=0;bitCount=0;
      if(pos+4>src.length)throw new Error("deflate stream truncated");
      const len=src[pos]|(src[pos+1]<<8);
      const nlen=src[pos+2]|(src[pos+3]<<8);
      pos+=4;
      if((len^0xffff)!==nlen)throw new Error("bad stored block length");
      if(pos+len>src.length)throw new Error("deflate stream truncated");
      if(outPos+len>expectedLength)throw new Error("deflate output too long");
      out.set(src.subarray(pos,pos+len),outPos);
      pos+=len;
      outPos+=len;
    }else if(type===1){
      fixedTables();
      inflateBlock(fixedLiteral,fixedDistance);
    }else if(type===2){
      const literalCount=bits(5)+257;
      const distanceCount=bits(5)+1;
      const codeLengthCount=bits(4)+4;
      if(literalCount>286||distanceCount>30)throw new Error("bad dynamic block header");
      const codeLengths=new Uint8Array(19);
      for(let i=0;i<codeLengthCount;i++)codeLengths[CODE_LENGTH_ORDER[i]]=bits(3);
      const codeTable=buildHuffman(codeLengths,19);
      const lengths=new Uint8Array(literalCount+distanceCount);
      let i=0;
      while(i<literalCount+distanceCount){
        const symbol=decodeSymbol(codeTable);
        if(symbol<16){
          lengths[i++]=symbol;
        }else{
          let repeat=0,value=0;
          if(symbol===16){
            if(i===0)throw new Error("bad code length repeat");
            value=lengths[i-1];
            repeat=3+bits(2);
          }else if(symbol===17){
            repeat=3+bits(3);
          }else{
            repeat=11+bits(7);
          }
          if(i+repeat>literalCount+distanceCount)throw new Error("bad code lengths");
          while(repeat--)lengths[i++]=value;
        }
      }
      if(lengths[256]===0)throw new Error("dynamic block has no end code");
      const literal=buildHuffman(lengths.subarray(0,literalCount),literalCount);
      const distance=buildHuffman(lengths.subarray(literalCount),distanceCount);
      inflateBlock(literal,distance);
    }else{
      throw new Error("bad deflate block type");
    }
  }while(!last);
  if(outPos!==expectedLength)throw new Error("deflate output too short");
  return out;
}

function expandIndices(indices,palette,count){
  const paletteCount=palette.length>>2;
  const pixels=new Uint8Array(count*4);
  for(let i=0;i<count;i++){
    const index=indices[i];
    if(index>=paletteCount)throw new Error("sprite palette index out of range");
    const slot=index*4,out=i*4;
    pixels[out]=palette[slot];
    pixels[out+1]=palette[slot+1];
    pixels[out+2]=palette[slot+2];
    pixels[out+3]=palette[slot+3];
  }
  return pixels;
}

function decodeSprite(encoding,payload,width,height,lookup){
  const count=width*height;
  const expected=count*4;
  if(payload.length===0){
    return {pixels:new Uint8Array(0),indices:null,palette:null};
  }
  if(encoding===0x00){
    if(!root.SnappyJS)throw new Error("SnappyJS is not loaded");
    const raw=root.SnappyJS.uncompress(payload,expected);
    const pixels=raw instanceof Uint8Array?raw:new Uint8Array(raw);
    if(pixels.length!==expected)throw new Error("Bad sprite pixel length");
    return {pixels,indices:null,palette:null};
  }
  if(encoding===0x01){
    return {pixels:inflate(payload,expected),indices:null,palette:null};
  }
  if(encoding===0x02){
    const paletteCount=payload[0]+1;
    const paletteEnd=1+paletteCount*4;
    if(payload.length<paletteEnd)throw new Error("truncated sprite palette");
    const palette=payload.slice(1,paletteEnd);
    const indices=inflate(payload.subarray(paletteEnd),count);
    return {pixels:expandIndices(indices,palette,count),indices,palette};
  }
  if(encoding===0x03){
    if(payload.length<3)throw new Error("truncated palette swap");
    const sourceId=payload[0]|(payload[1]<<8);
    const paletteCount=payload[2]+1;
    const paletteEnd=3+paletteCount*4;
    if(payload.length<paletteEnd)throw new Error("truncated sprite palette");
    const palette=payload.slice(3,paletteEnd);
    const source=lookup?lookup(sourceId):null;
    if(!source||!source.indices||source.indices.length!==count){
      throw new Error("palette swap source "+sourceId+" is not an indexed sprite of the same size");
    }
    return {pixels:expandIndices(source.indices,palette,count),indices:source.indices,palette};
  }
  throw new Error("unknown sprite encoding "+encoding);
}

// Parses the fields after the message type byte of one Define Encoded
// Sprite message. Returns {id, width, height, encoding, payload,
// label, offset} with `offset` past the label, or null when the packet
// is truncated.
function readEncodedSprite(bytes,offset,textDecoder){
  if(offset+11>bytes.length)return null;
  const id=bytes[offset]|(bytes[offset+1]<<8);
  const width=bytes[offset+2]|(bytes[offset+3]<<8);
  const height=bytes[offset+4]|(bytes[offset+5]<<8);
  const encoding=bytes[offset+6];
  const payloadLength=(bytes[offset+7]|(bytes[offset+8]<<8)|(bytes[offset+9]<<16)|(bytes[offset+10]*0x1000000))>>>0;
  offset+=11;
  if(offset+payloadLength+2>bytes.length)return null;
  const payload=bytes.subarray(offset,offset+payloadLength);
  offset+=payloadLength;
  const labelLength=bytes[offset]|(bytes[offset+1]<<8);
  offset+=2;
  if(offset+labelLength>bytes.length)return null;
  const label=textDecoder?textDecoder.decode(bytes.slice(offset,offset+labelLength)):"";
  offset+=labelLength;
  return {id,width,height,encoding,payload,label,offset};
}

root.SpriteCodec={inflate,expandIndices,decodeSprite,readEncodedSprite};
})(typeof window!=="undefined"?window:globalThis);
