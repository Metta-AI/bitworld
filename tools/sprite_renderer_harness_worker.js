// Worker side of tools/sprite_renderer_harness.html: runs the shared Sprite
// v1 renderer on a transferred OffscreenCanvas and reports pixel checksums
// and outgoing input packets for comparison with the Window run.
"use strict";

importScripts("/client/snappyjs.min.js", "/client/sprite_renderer.js");

function checksum(data) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < data.length; index++) {
    hash = ((hash ^ data[index]) * 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

function nextFrame() {
  return new Promise(resolve => requestAnimationFrame(() => resolve()));
}

onmessage = async event => {
  try {
    const { canvas, size, stream, inputScript } = event.data;
    const packets = [];
    const renderer = BitworldSpriteRenderer.create({
      canvas,
      width: size,
      height: size,
      dpr: 1,
      onPacket: packet => packets.push([...packet])
    });
    renderer.ingest(stream);
    await nextFrame();
    await nextFrame();
    const ctx = canvas.getContext("2d");
    const first = checksum(ctx.getImageData(0, 0, canvas.width, canvas.height).data);
    for (const message of inputScript) renderer.handleInput(message);
    await nextFrame();
    await nextFrame();
    const second = checksum(ctx.getImageData(0, 0, canvas.width, canvas.height).data);
    renderer.resize(size / 2, size / 2, 2);
    await nextFrame();
    await nextFrame();
    const third = checksum(ctx.getImageData(0, 0, canvas.width, canvas.height).data);
    renderer.dispose();
    postMessage({ checksums: [first, second, third], packets });
  } catch (error) {
    postMessage({ error: error.message });
  }
};
