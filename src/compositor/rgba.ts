import {
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
  RGBA_BYTE_LENGTH,
  RGBA_STRIDE_BYTES,
} from './types.js';

export function rgbaBytes(data: Uint8ClampedArray): Uint8Array {
  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
}

export function assertRawRgbaLayout(frame: RawRgbaFrame): void {
  if (
    frame.width !== OUTPUT_WIDTH ||
    frame.height !== OUTPUT_HEIGHT ||
    frame.strideBytes !== RGBA_STRIDE_BYTES ||
    frame.byteLength !== RGBA_BYTE_LENGTH ||
    frame.data.byteLength !== RGBA_BYTE_LENGTH
  ) {
    throw new Error('Raw RGBA frame violates output layout contract');
  }
}

export function isOpaqueRgba(data: Uint8Array): boolean {
  if (data.byteLength % 4 !== 0) throw new Error('RGBA byte length must be divisible by four');
  for (let alpha = 3; alpha < data.byteLength; alpha += 4) {
    if (data[alpha] !== 255) return false;
  }
  return true;
}
