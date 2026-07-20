export interface JpegDimensions {
  width: number;
  height: number;
}

const START_OF_FRAME_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

export function readJpegDimensions(data: Buffer): JpegDimensions {
  if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8) {
    throw new Error('Invalid JPEG start-of-image marker');
  }

  let offset = 2;
  while (offset + 3 < data.length) {
    if (data[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    while (data[offset] === 0xff) offset += 1;
    const marker = data[offset];
    offset += 1;
    if (marker === undefined || marker === 0xd9 || marker === 0xda) break;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 1 >= data.length) break;

    const segmentLength = data.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > data.length) {
      throw new Error('Invalid JPEG segment length');
    }
    if (START_OF_FRAME_MARKERS.has(marker)) {
      if (segmentLength < 7) throw new Error('Invalid JPEG start-of-frame segment');
      return {
        height: data.readUInt16BE(offset + 3),
        width: data.readUInt16BE(offset + 5),
      };
    }
    offset += segmentLength;
  }

  throw new Error('JPEG dimensions were not found');
}
