// Bit World's canonical browser Sprite v1 renderer (docs/sprite_v1.md).
//
// This is a classic script, loadable both from a page (<script>) and from a
// Dedicated Worker (importScripts). It has no Window/DOM dependencies: hosts
// hand it a canvas (an HTMLCanvasElement on a page, a transferred
// OffscreenCanvas in a Worker), feed server packets through ingest(), forward
// pointer input through handleInput(), and receive outgoing client packets
// through the onPacket callback. Transport (WebSocket, WASM replay feed, ...)
// stays entirely on the host side.
//
// Exports on the global scope:
//   BitworldSpriteRenderer.create(config) -> renderer
//     config: {canvas, width, height, dpr, onPacket, onDraw, onDebug, onError}
//     renderer: {ingest, resize, handleInput, setDebug, dispose}
//   plus the protocol building blocks (parsePackets, byte codecs, sprite
//   decoders, putSpritePixel, input-packet encoders) for hosts that keep
//   their own game-specific composition policy.
//
// Snappy sprite payloads are decoded with SnappyJS (client/snappyjs.min.js),
// which the host must load first in the same scope.
(function (scope) {
  "use strict";

  const ZoomableFlag = 1;
  const UiFlag = 2;
  const MapLayerType = 0;
  const FullScreenLayerType = 9;
  const MaxUiZoom = 3;
  const MaxUiZoomFitPadding = 1.5;
  const DebugUpdateFlashMs = 900;
  const textDecoder = new TextDecoder("utf-8");
  const requestFrame = typeof scope.requestAnimationFrame === "function"
    ? scope.requestAnimationFrame.bind(scope)
    : callback => setTimeout(() => callback(performance.now()), 1000 / 60);
  const cancelFrame = typeof scope.cancelAnimationFrame === "function"
    ? scope.cancelAnimationFrame.bind(scope)
    : clearTimeout;

  // PICO-8-style 16-color palette for raw-palette sprite payloads (e.g.
  // Persephone's Escape). Index 0 = fully transparent; indices 1-16 map to
  // palette entries 0-15.
  const Palette = [
    [0, 0, 0], [194, 195, 199], [255, 241, 232], [255, 0, 77],
    [255, 119, 168], [95, 87, 79], [171, 82, 54], [255, 163, 0],
    [255, 236, 39], [126, 37, 83], [0, 135, 81], [0, 228, 54],
    [29, 43, 83], [131, 118, 156], [41, 173, 255], [255, 204, 170]
  ];

  function readU16(bytes, offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  function readU32(bytes, offset) {
    return (bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] * 0x1000000)) >>> 0;
  }

  function readI16(bytes, offset) {
    const value = readU16(bytes, offset);
    return value & 0x8000 ? value - 0x10000 : value;
  }

  function writeI16(bytes, offset, value) {
    value = Math.max(-32768, Math.min(32767, value)) & 0xffff;
    bytes[offset] = value & 255;
    bytes[offset + 1] = value >> 8;
  }

  function writeU16(bytes, offset, value) {
    value = Math.max(0, Math.min(65535, value)) & 0xffff;
    bytes[offset] = value & 255;
    bytes[offset + 1] = value >> 8;
  }

  function asciiBytes(text) {
    const bytes = [];
    for (let index = 0; index < text.length; index++) {
      const code = text.charCodeAt(index);
      if (code >= 32 && code < 127) bytes.push(code);
    }
    return bytes;
  }

  // Encodes an Input Text (0x81) packet, or returns null when nothing
  // printable remains after ASCII filtering.
  function encodeInputText(text) {
    const bytes = asciiBytes(text).slice(0, 65535);
    if (bytes.length === 0) return null;
    const packet = new Uint8Array(bytes.length + 3);
    packet[0] = 0x81;
    writeU16(packet, 1, bytes.length);
    packet.set(bytes, 3);
    return packet;
  }

  // Encodes a Player Input (0x84) packet. Bit 7 is reserved.
  function encodePlayerButtons(buttons) {
    return new Uint8Array([0x84, buttons & 127]);
  }

  function decodeSpritePixelsSnappy(compressed, width, height) {
    if (!scope.SnappyJS) throw new Error("SnappyJS is not loaded");
    const expected = width * height * 4;
    const pixels = scope.SnappyJS.uncompress(compressed, expected);
    const rgba = pixels instanceof Uint8Array ? pixels : new Uint8Array(pixels);
    if (rgba.length !== expected) throw new Error("Bad sprite pixel length");
    return rgba;
  }

  // Probes a Define Sprite payload for the snappy framing (u32 compressed
  // length, compressed RGBA, u16 label length, UTF-8 label). Returns null
  // when the framing itself is implausible. When the framing is valid but
  // decompression fails, returns pixels:null with the compressed payload
  // retained so callers can advance past the message and retry the decode
  // later instead of desyncing the stream.
  function tryDecodeSpritePixelsSnappy(bytes, offset, remaining, width, height) {
    if (remaining < 6) return null;
    const compressedLength = readU32(bytes, offset);
    if (compressedLength > remaining - 6) return null;
    const labelOffset = offset + 4 + compressedLength;
    const labelLength = readU16(bytes, labelOffset);
    if (labelLength > remaining - 4 - compressedLength - 2) return null;
    const compressed = bytes.slice(offset + 4, labelOffset);
    const labelStart = labelOffset + 2;
    const labelEnd = labelStart + labelLength;
    const label = textDecoder.decode(bytes.slice(labelStart, labelEnd));
    let pixels = null;
    try {
      pixels = decodeSpritePixelsSnappy(compressed, width, height);
    } catch (ignored) {
      // Framing was plausible but the payload did not decompress.
    }
    return { pixels, compressed, label, offset: labelEnd };
  }

  function decodeSpritePixelsRaw(bytes, offset, width, height) {
    const count = width * height;
    const pixels = new Uint8Array(count * 4);
    for (let index = 0; index < count; index++) {
      const colorIndex = bytes[offset + index];
      if (colorIndex === 0) continue;
      const color = Palette[(colorIndex - 1) & 15];
      const out = index * 4;
      pixels[out] = color[0];
      pixels[out + 1] = color[1];
      pixels[out + 2] = color[2];
      pixels[out + 3] = 255;
    }
    return pixels;
  }

  // Composites one sprite pixel into an ImageData with straight-alpha
  // source-over blending. Fast paths: transparent source, opaque source,
  // and empty destination.
  function putSpritePixel(image, x, y, pixels, srcOffset) {
    if (x < 0 || y < 0 || x >= image.width || y >= image.height) return;
    const srcA = pixels[srcOffset + 3];
    if (srcA === 0) return;
    const offset = (y * image.width + x) * 4;
    if (srcA === 255 || image.data[offset + 3] === 0) {
      image.data[offset] = pixels[srcOffset];
      image.data[offset + 1] = pixels[srcOffset + 1];
      image.data[offset + 2] = pixels[srcOffset + 2];
      image.data[offset + 3] = srcA;
      return;
    }
    const dstA = image.data[offset + 3];
    const srcAlpha = srcA / 255;
    const dstAlpha = dstA / 255;
    const outAlpha = srcAlpha + dstAlpha * (1 - srcAlpha);
    const dstWeight = dstAlpha * (1 - srcAlpha);
    image.data[offset] = Math.round(
      (pixels[srcOffset] * srcAlpha + image.data[offset] * dstWeight) / outAlpha
    );
    image.data[offset + 1] = Math.round(
      (pixels[srcOffset + 1] * srcAlpha + image.data[offset + 1] * dstWeight) / outAlpha
    );
    image.data[offset + 2] = Math.round(
      (pixels[srcOffset + 2] * srcAlpha + image.data[offset + 2] * dstWeight) / outAlpha
    );
    image.data[offset + 3] = Math.round(outAlpha * 255);
  }

  // Parses a buffer of concatenated Sprite v1 server messages, invoking the
  // matching handler for each one:
  //   onSprite(id, {width, height, pixels, compressed, label}, packetBytes)
  //   onObject({id, x, y, z, layer, spriteId})
  //   onDeleteObject(id), onClearObjects()
  //   onViewport(layerId, width, height), onLayer(id, type, flags)
  //   onIdentity(objectId)
  // Throws on unknown message types and truncated messages; the host decides
  // what to do with a poisoned stream (e.g. close the socket).
  //
  // options.rawPaletteFallback (default true): when a sprite payload does not
  // carry valid snappy framing, decode it as a raw-palette payload. Disable
  // for streams where snappy is mandatory; sprites whose framing is valid but
  // whose payload fails to decompress are then delivered with pixels:null and
  // the compressed payload retained for retry.
  function parsePackets(bytes, handlers, options = {}) {
    const rawPaletteFallback = options.rawPaletteFallback !== false;
    let offset = 0;
    const need = count => {
      if (bytes.length - offset < count) {
        throw new Error("Truncated Sprite v1 message");
      }
    };
    while (offset < bytes.length) {
      const type = bytes[offset++];
      if (type === 0x01) {
        const packetStart = offset - 1;
        need(6);
        const id = readU16(bytes, offset);
        const width = readU16(bytes, offset + 2);
        const height = readU16(bytes, offset + 4);
        offset += 6;
        const remaining = bytes.length - offset;
        const snappySprite =
          tryDecodeSpritePixelsSnappy(bytes, offset, remaining, width, height);
        let sprite;
        if (snappySprite && (snappySprite.pixels || !rawPaletteFallback)) {
          sprite = {
            width,
            height,
            pixels: snappySprite.pixels,
            compressed: snappySprite.pixels ? null : snappySprite.compressed,
            label: snappySprite.label
          };
          offset = snappySprite.offset;
        } else if (rawPaletteFallback) {
          need(width * height);
          sprite = {
            width,
            height,
            pixels: decodeSpritePixelsRaw(bytes, offset, width, height),
            compressed: null,
            label: ""
          };
          offset += width * height;
        } else {
          throw new Error("Sprite " + id + " has an unparseable pixel payload");
        }
        if (handlers.onSprite) handlers.onSprite(id, sprite, offset - packetStart);
      } else if (type === 0x02) {
        need(11);
        const object = {
          id: readU16(bytes, offset),
          x: readI16(bytes, offset + 2),
          y: readI16(bytes, offset + 4),
          z: readI16(bytes, offset + 6),
          layer: bytes[offset + 8],
          spriteId: readU16(bytes, offset + 9)
        };
        offset += 11;
        if (handlers.onObject) handlers.onObject(object);
      } else if (type === 0x03) {
        need(2);
        const id = readU16(bytes, offset);
        offset += 2;
        if (handlers.onDeleteObject) handlers.onDeleteObject(id);
      } else if (type === 0x04) {
        if (handlers.onClearObjects) handlers.onClearObjects();
      } else if (type === 0x05) {
        need(5);
        const layerId = bytes[offset];
        const width = readU16(bytes, offset + 1);
        const height = readU16(bytes, offset + 3);
        offset += 5;
        if (handlers.onViewport) handlers.onViewport(layerId, width, height);
      } else if (type === 0x06) {
        need(3);
        const layerId = bytes[offset];
        const layerType = bytes[offset + 1];
        const flags = bytes[offset + 2];
        offset += 3;
        if (handlers.onLayer) handlers.onLayer(layerId, layerType, flags);
      } else if (type === 0x07) {
        // Identity extension (stag_hunt): u16 self object id. Not part of
        // docs/sprite_v1.md; browser viewers skip it.
        need(2);
        const objectId = readU16(bytes, offset);
        offset += 2;
        if (handlers.onIdentity) handlers.onIdentity(objectId);
      } else {
        throw new Error("Unknown Sprite v1 packet type " + type);
      }
    }
  }

  function createRenderer(config) {
    const canvas = config.canvas;
    const ctx = canvas && canvas.getContext("2d");
    if (!ctx) throw new Error("Canvas 2D rendering is unavailable");

    const layers = new Map();
    const sprites = new Map();
    const objects = new Map();
    let viewportWidth = Math.max(1, Number(config.width) || 1);
    let viewportHeight = Math.max(1, Number(config.height) || 1);
    let pixelRatio = Math.max(0.1, Number(config.dpr) || 1);
    let zoom = 1;
    let panX = 0;
    let panY = 0;
    let autoFit = true;
    let activeMouseLayer = null;
    let draggingMap = false;
    let dragX = 0;
    let dragY = 0;
    let drawPending = false;
    let drawHandle = 0;
    let debugOpen = false;
    let debugSpritesDirty = true;
    let debugSpriteTimer = 0;
    let debugUpdateTimer = 0;
    let debugBytesDown = 0;
    let debugBytesUp = 0;
    let disposed = false;

    ctx.imageSmoothingEnabled = false;

    function fail(error) {
      if (config.onError) config.onError(error);
      else throw error;
    }

    function createSurface(width = 1, height = 1) {
      return new OffscreenCanvas(Math.max(1, width), Math.max(1, height));
    }

    function applyView() {
      const width = Math.max(1, Math.round(viewportWidth * pixelRatio));
      const height = Math.max(1, Math.round(viewportHeight * pixelRatio));
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;
    }

    function mapLayer() {
      for (const layer of layers.values()) {
        if (isMapLayer(layer)) return layer;
      }
      return null;
    }

    function isMapLayer(layer) {
      return !!layer && ((layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType);
    }

    function isFullScreenLayer(layer) {
      return !!layer && layer.type === FullScreenLayerType;
    }

    function isUiLayer(layer) {
      return !!layer && (layer.flags & UiFlag) !== 0;
    }

    function layerDrawRank(layer) {
      if (isMapLayer(layer)) return 0;
      if (isFullScreenLayer(layer)) return 1;
      return 2;
    }

    function fit() {
      const layer = mapLayer();
      const width = layer ? layer.width : 1;
      const height = layer ? layer.height : 1;
      zoom = Math.max(0.1, Math.min(viewportWidth / width, viewportHeight / height));
      panX = Math.floor((viewportWidth - width * zoom) / 2);
      panY = Math.floor((viewportHeight - height * zoom) / 2);
      applyView();
      scheduleDraw();
    }

    function zoomMapAt(clientX, clientY, deltaY) {
      const layer = mapLayer();
      if (!layer) return;
      autoFit = false;
      const beforeX = (clientX - panX) / zoom;
      const beforeY = (clientY - panY) / zoom;
      const factor = deltaY < 0 ? 1.015 : 1 / 1.015;
      zoom = Math.min(64, Math.max(0.1, zoom * factor));
      panX = clientX - beforeX * zoom;
      panY = clientY - beforeY * zoom;
      applyView();
      scheduleDraw();
    }

    function maybeFit() {
      if (autoFit) fit();
      else applyView();
    }

    function clearBlack() {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    }

    function mapPoint(event) {
      return {
        x: Math.floor((event.clientX - panX) / zoom),
        y: Math.floor((event.clientY - panY) / zoom),
        layer: (mapLayer() || { id: 0 }).id
      };
    }

    function screenLayerPoint(event, layer) {
      if (!layer || !layer.image) return null;
      const pos = layerScreenPos(layer);
      return {
        x: Math.floor((event.clientX - pos.x) * layer.width / pos.w),
        y: Math.floor((event.clientY - pos.y) * layer.height / pos.h),
        layer: layer.id
      };
    }

    function layerHasObjects(layer) {
      for (const object of objects.values()) {
        if (object.layer === layer.id) return true;
      }
      return false;
    }

    function mousePoint(event, preferredLayer = null) {
      if (preferredLayer !== null) {
        const layer = layers.get(preferredLayer);
        if (isMapLayer(layer)) return mapPoint(event);
        if (!isFullScreenLayer(layer) || layerHasObjects(layer)) {
          const point = screenLayerPoint(event, layer);
          if (point) return point;
        }
      }
      const orderedLayers = [...layers.values()].sort((a, b) =>
        layerDrawRank(b) - layerDrawRank(a) || b.type - a.type || b.id - a.id
      );
      for (const layer of orderedLayers) {
        if (!layer.image || !isUiLayer(layer)) continue;
        const pos = layerScreenPos(layer);
        if (event.clientX < pos.x || event.clientY < pos.y ||
            event.clientX >= pos.x + pos.w || event.clientY >= pos.y + pos.h) continue;
        return screenLayerPoint(event, layer);
      }
      for (const layer of orderedLayers) {
        if (!layer.image || !isFullScreenLayer(layer) || !layerHasObjects(layer)) continue;
        return screenLayerPoint(event, layer);
      }
      return mapPoint(event);
    }

    function sendPacket(bytes) {
      debugBytesUp += bytes.byteLength || bytes.length || 0;
      if (config.onPacket) config.onPacket(bytes);
      sendDebugSnapshotSoon();
    }

    function sendMousePosition(event, preferredLayer = null) {
      const point = mousePoint(event, preferredLayer);
      if (!point) return;
      const bytes = new Uint8Array(6);
      bytes[0] = 0x82;
      writeI16(bytes, 1, point.x);
      writeI16(bytes, 3, point.y);
      bytes[5] = point.layer & 255;
      sendPacket(bytes);
    }

    function sendMouseButton(event, down, preferredLayer = null) {
      const point = mousePoint(event, preferredLayer);
      if (!point) return;
      const bytes = new Uint8Array(9);
      bytes[0] = 0x82;
      writeI16(bytes, 1, point.x);
      writeI16(bytes, 3, point.y);
      bytes[5] = point.layer & 255;
      bytes[6] = 0x83;
      bytes[7] = 0x01;
      bytes[8] = down ? 1 : 0;
      sendPacket(bytes);
    }

    function ensureLayer(id) {
      if (!layers.has(id)) {
        layers.set(id, {
          id,
          type: MapLayerType,
          flags: ZoomableFlag,
          width: 1,
          height: 1,
          canvas: createSurface(),
          ctx: null,
          mips: [],
          image: null
        });
      }
      const layer = layers.get(id);
      if (!layer.ctx) layer.ctx = layer.canvas.getContext("2d");
      if (!layer.ctx) throw new Error("Unable to create a Sprite v1 layer context");
      layer.ctx.imageSmoothingEnabled = false;
      return layer;
    }

    function defineLayer(id, type, flags) {
      const layer = ensureLayer(id);
      layer.type = type;
      layer.flags = flags;
    }

    function setViewport(layerId, width, height) {
      const layer = ensureLayer(layerId);
      layer.width = width;
      layer.height = height;
      layer.canvas.width = width;
      layer.canvas.height = height;
      layer.mips = [];
      layer.image = layer.ctx.createImageData(width, height);
      maybeFit();
    }

    function uiZoom() {
      let nextZoom = MaxUiZoom;
      for (const layer of layers.values()) {
        if (!isUiLayer(layer)) continue;
        const layerFit = Math.min(viewportWidth / layer.width, viewportHeight / layer.height);
        let layerZoom = 1;
        for (let scale = MaxUiZoom; scale >= 2; scale--) {
          if (layerFit >= scale * MaxUiZoomFitPadding) {
            layerZoom = scale;
            break;
          }
        }
        nextZoom = Math.min(nextZoom, layerZoom);
      }
      return nextZoom;
    }

    function layerScale(layer, pos) {
      return Math.min(Math.abs(pos.w) / layer.width, Math.abs(pos.h) / layer.height);
    }

    function layerMipLevel(layer, pos) {
      const scale = layerScale(layer, pos);
      if (!isFinite(scale) || scale >= 1) return 0;
      return Math.max(0, Math.floor(Math.log2(1 / Math.max(scale, 0.000001))));
    }

    function layerMipCanvas(layer, level) {
      let source = layer.canvas;
      for (let index = 1; index <= level; index++) {
        const width = Math.max(1, Math.floor(source.width / 2));
        const height = Math.max(1, Math.floor(source.height / 2));
        let mip = layer.mips[index - 1];
        if (!mip) {
          mip = { canvas: createSurface(), ctx: null };
          layer.mips[index - 1] = mip;
        }
        if (mip.canvas.width !== width) mip.canvas.width = width;
        if (mip.canvas.height !== height) mip.canvas.height = height;
        if (!mip.ctx) mip.ctx = mip.canvas.getContext("2d");
        mip.ctx.clearRect(0, 0, width, height);
        mip.ctx.imageSmoothingEnabled = true;
        mip.ctx.imageSmoothingQuality = "high";
        mip.ctx.drawImage(source, 0, 0, width, height);
        source = mip.canvas;
        if (width === 1 && height === 1) break;
      }
      return source;
    }

    function drawLayerCanvas(layer, pos) {
      const scale = layerScale(layer, pos);
      let source = layer.canvas;
      if (scale < 1) {
        source = layerMipCanvas(layer, layerMipLevel(layer, pos));
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
      } else {
        ctx.imageSmoothingEnabled = false;
      }
      ctx.drawImage(source, pos.x, pos.y, pos.w, pos.h);
      ctx.imageSmoothingEnabled = false;
    }

    function layerScreenPos(layer) {
      if (isFullScreenLayer(layer)) {
        const scale = Math.max(0.000001, Math.min(
          viewportWidth / Math.max(1, layer.width),
          viewportHeight / Math.max(1, layer.height)
        ));
        const width = layer.width * scale;
        const height = layer.height * scale;
        return {
          x: Math.floor((viewportWidth - width) / 2),
          y: Math.floor((viewportHeight - height) / 2),
          w: width,
          h: height
        };
      }
      const scale = isUiLayer(layer) ? uiZoom() : 1;
      const width = layer.width * scale;
      const height = layer.height * scale;
      if (isMapLayer(layer)) {
        return { x: panX, y: panY, w: layer.width * zoom, h: layer.height * zoom };
      }
      switch (layer.type) {
        case 1: return { x: 0, y: 0, w: width, h: height };
        case 2: return { x: viewportWidth - width, y: 0, w: width, h: height };
        case 3: return { x: viewportWidth - width, y: viewportHeight - height, w: width, h: height };
        case 4: return { x: 0, y: viewportHeight - height, w: width, h: height };
        case 5: return { x: (viewportWidth - width) / 2, y: 0, w: width, h: height };
        case 6: return { x: viewportWidth - width, y: (viewportHeight - height) / 2, w: width, h: height };
        case 7: return { x: 0, y: (viewportHeight - height) / 2, w: width, h: height };
        case 8: return { x: (viewportWidth - width) / 2, y: viewportHeight - height, w: width, h: height };
        default: return { x: 0, y: 0, w: width, h: height };
      }
    }

    function debugSpriteColor(id) {
      return "hsl(" + ((id * 137.508) % 360) + ",90%,55%)";
    }

    function spriteJustUpdated(sprite) {
      return sprite.updatedUntil && performance.now() < sprite.updatedUntil;
    }

    function drawDebugSpriteBounds(layer, pos, object, sprite) {
      const scaleX = pos.w / layer.width;
      const scaleY = pos.h / layer.height;
      const x = pos.x + object.x * scaleX;
      const y = pos.y + object.y * scaleY;
      const width = sprite.width * scaleX;
      const height = sprite.height * scaleY;
      const color = debugSpriteColor(object.spriteId);
      const label = sprite.label || ("sprite " + object.spriteId);
      const bx = Math.round(x) + 0.5;
      const by = Math.round(y) + 0.5;
      const bw = Math.max(1, Math.round(width));
      const bh = Math.max(1, Math.round(height));
      ctx.save();
      ctx.lineWidth = 1;
      if (spriteJustUpdated(sprite)) {
        ctx.strokeStyle = "#fff";
        ctx.strokeRect(bx - 1, by - 1, bw + 2, bh + 2);
      }
      ctx.strokeStyle = color;
      ctx.strokeRect(bx, by, bw, bh);
      ctx.font = "8px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace";
      ctx.textBaseline = "top";
      const textWidth = Math.ceil(ctx.measureText(label).width);
      const labelX = Math.max(0, Math.min(viewportWidth - textWidth - 4, Math.round(x)));
      const labelY = Math.max(0, Math.min(viewportHeight - 10, Math.round(y) - 9));
      ctx.fillStyle = color;
      ctx.fillRect(labelX, labelY, textWidth + 4, 9);
      ctx.fillStyle = "#000";
      ctx.fillText(label, labelX + 2, labelY + 1);
      ctx.restore();
    }

    function draw() {
      if (disposed) return;
      clearBlack();
      ctx.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
      ctx.imageSmoothingEnabled = false;
      const orderedLayers = [...layers.values()].sort((a, b) =>
        layerDrawRank(a) - layerDrawRank(b) || a.type - b.type || a.id - b.id
      );
      for (const layer of orderedLayers) {
        if (!layer.image) continue;
        const ordered = [...objects.values()]
          .filter(object => object.layer === layer.id)
          .sort((a, b) => a.z - b.z || a.y - b.y || a.id - b.id);
        if (isUiLayer(layer) && ordered.length === 0) continue;
        layer.image.data.fill(0);
        for (const object of ordered) {
          const sprite = sprites.get(object.spriteId);
          if (!sprite) continue;
          const startX = Math.max(0, -object.x);
          const startY = Math.max(0, -object.y);
          const endX = Math.min(sprite.width, layer.width - object.x);
          const endY = Math.min(sprite.height, layer.height - object.y);
          if (startX >= endX || startY >= endY) continue;
          for (let y = startY; y < endY; y++) {
            for (let x = startX; x < endX; x++) {
              putSpritePixel(
                layer.image,
                object.x + x,
                object.y + y,
                sprite.pixels,
                (y * sprite.width + x) * 4
              );
            }
          }
        }
        layer.ctx.putImageData(layer.image, 0, 0);
        const pos = layerScreenPos(layer);
        drawLayerCanvas(layer, pos);
        if (debugOpen) {
          for (const object of ordered) {
            const sprite = sprites.get(object.spriteId);
            if (sprite) drawDebugSpriteBounds(layer, pos, object, sprite);
          }
        }
      }
      if (config.onDraw) config.onDraw();
    }

    function scheduleDraw() {
      if (drawPending || disposed) return;
      drawPending = true;
      drawHandle = requestFrame(() => {
        drawPending = false;
        drawHandle = 0;
        try {
          draw();
        } catch (error) {
          fail(error);
        }
      });
    }

    function previewSprite(surface, sprite) {
      const size = 64;
      const previewCtx = surface.getContext("2d");
      const image = previewCtx.createImageData(size, size);
      for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
          const offset = (y * size + x) * 4;
          const shade = ((Math.floor(x / 8) + Math.floor(y / 8)) & 1) ? 44 : 28;
          image.data[offset] = shade;
          image.data[offset + 1] = shade;
          image.data[offset + 2] = shade;
          image.data[offset + 3] = 255;
        }
      }
      const scale = Math.min(size / sprite.width, size / sprite.height);
      const drawWidth = Math.max(1, Math.floor(sprite.width * scale));
      const drawHeight = Math.max(1, Math.floor(sprite.height * scale));
      const baseX = Math.floor((size - drawWidth) / 2);
      const baseY = Math.floor((size - drawHeight) / 2);
      for (let y = 0; y < drawHeight; y++) {
        for (let x = 0; x < drawWidth; x++) {
          const srcX = Math.min(sprite.width - 1, Math.floor(x / scale));
          const srcY = Math.min(sprite.height - 1, Math.floor(y / scale));
          const srcOffset = (srcY * sprite.width + srcX) * 4;
          const alpha = sprite.pixels[srcOffset + 3] / 255;
          if (alpha === 0) continue;
          const outOffset = ((baseY + y) * size + baseX + x) * 4;
          image.data[outOffset] = Math.round(
            sprite.pixels[srcOffset] * alpha + image.data[outOffset] * (1 - alpha)
          );
          image.data[outOffset + 1] = Math.round(
            sprite.pixels[srcOffset + 1] * alpha + image.data[outOffset + 1] * (1 - alpha)
          );
          image.data[outOffset + 2] = Math.round(
            sprite.pixels[srcOffset + 2] * alpha + image.data[outOffset + 2] * (1 - alpha)
          );
        }
      }
      previewCtx.putImageData(image, 0, 0);
    }

    function sendDebugSnapshot() {
      debugSpriteTimer = 0;
      if (!debugOpen || !debugSpritesDirty || disposed || !config.onDebug) return;
      debugSpritesDirty = false;
      try {
        const entries = [];
        const transfers = [];
        const ids = [...sprites.keys()].sort((a, b) => a - b);
        for (const id of ids) {
          const sprite = sprites.get(id);
          const preview = createSurface(64, 64);
          previewSprite(preview, sprite);
          const bitmap = preview.transferToImageBitmap();
          entries.push({
            id,
            width: sprite.width,
            height: sprite.height,
            label: sprite.label,
            updates: sprite.updates || 0,
            bytesDown: sprite.bytesDown || 0,
            updated: !!spriteJustUpdated(sprite),
            bitmap
          });
          transfers.push(bitmap);
        }
        config.onDebug({ bytesDown: debugBytesDown, bytesUp: debugBytesUp, sprites: entries }, transfers);
      } catch (error) {
        fail(error);
      }
    }

    function sendDebugSnapshotSoon() {
      debugSpritesDirty = true;
      if (!debugOpen || debugSpriteTimer || disposed) return;
      debugSpriteTimer = setTimeout(sendDebugSnapshot, 120);
    }

    function scheduleDebugUpdateClear() {
      if (debugUpdateTimer) clearTimeout(debugUpdateTimer);
      debugUpdateTimer = setTimeout(() => {
        debugUpdateTimer = 0;
        if (!debugOpen || disposed) return;
        debugSpritesDirty = true;
        sendDebugSnapshot();
        scheduleDraw();
      }, DebugUpdateFlashMs + 40);
    }

    function parse(bytes) {
      parsePackets(bytes, {
        onSprite(id, sprite, packetBytes) {
          const previous = sprites.get(id);
          sprites.set(id, {
            width: sprite.width,
            height: sprite.height,
            pixels: sprite.pixels,
            label: sprite.label,
            updates: (previous ? previous.updates : 0) + 1,
            bytesDown: (previous ? previous.bytesDown : 0) + packetBytes,
            updatedUntil: performance.now() + DebugUpdateFlashMs
          });
          sendDebugSnapshotSoon();
          scheduleDebugUpdateClear();
        },
        onObject(object) {
          objects.set(object.id, object);
        },
        onDeleteObject(id) {
          objects.delete(id);
        },
        onClearObjects() {
          objects.clear();
        },
        onViewport: setViewport,
        onLayer: defineLayer
      });
      scheduleDraw();
    }

    function ingest(bytes) {
      if (disposed) return;
      const packet = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      debugBytesDown += packet.byteLength;
      try {
        parse(packet);
      } catch (error) {
        fail(error);
      }
      sendDebugSnapshotSoon();
    }

    function resize(width, height, dpr) {
      viewportWidth = Math.max(1, Number(width) || 1);
      viewportHeight = Math.max(1, Number(height) || 1);
      pixelRatio = Math.max(0.1, Number(dpr) || 1);
      maybeFit();
      scheduleDraw();
    }

    function handleInput(message) {
      if (disposed) return;
      const event = {
        clientX: Math.max(-32768, Math.min(32767, Number(message.x) || 0)),
        clientY: Math.max(-32768, Math.min(32767, Number(message.y) || 0))
      };
      switch (message.action) {
        case "wheel":
          zoomMapAt(event.clientX, event.clientY,
            Math.max(-1200, Math.min(1200, Number(message.deltaY) || 0)));
          break;
        case "pointerdown": {
          const point = mousePoint(event);
          activeMouseLayer = point ? point.layer : null;
          const layer = layers.get(activeMouseLayer);
          draggingMap = isMapLayer(layer);
          if (draggingMap) {
            autoFit = false;
            dragX = event.clientX - panX;
            dragY = event.clientY - panY;
          }
          sendMouseButton(event, true, activeMouseLayer);
          break;
        }
        case "pointermove":
          if (draggingMap) {
            panX = event.clientX - dragX;
            panY = event.clientY - dragY;
            applyView();
            scheduleDraw();
          }
          sendMousePosition(event, activeMouseLayer);
          break;
        case "pointerup":
        case "pointercancel":
          sendMouseButton(event, false, activeMouseLayer);
          draggingMap = false;
          activeMouseLayer = null;
          break;
        case "dblclick": {
          const point = mousePoint(event);
          const layer = point ? layers.get(point.layer) : null;
          if (isMapLayer(layer)) {
            autoFit = true;
            fit();
          }
          break;
        }
        default:
          throw new Error("Unknown Sprite v1 input action " + message.action);
      }
    }

    function setDebug(enabled) {
      debugOpen = !!enabled;
      debugSpritesDirty = true;
      if (debugOpen) sendDebugSnapshot();
      scheduleDraw();
    }

    function dispose() {
      disposed = true;
      if (drawHandle) cancelFrame(drawHandle);
      if (debugSpriteTimer) clearTimeout(debugSpriteTimer);
      if (debugUpdateTimer) clearTimeout(debugUpdateTimer);
      layers.clear();
      sprites.clear();
      objects.clear();
    }

    resize(viewportWidth, viewportHeight, pixelRatio);
    return { ingest, resize, handleInput, setDebug, dispose };
  }

  scope.BitworldSpriteRenderer = {
    create: createRenderer,
    parsePackets,
    readU16,
    readU32,
    readI16,
    writeU16,
    writeI16,
    decodeSpritePixelsSnappy,
    tryDecodeSpritePixelsSnappy,
    decodeSpritePixelsRaw,
    putSpritePixel,
    encodeInputText,
    encodePlayerButtons
  };
})(self);
