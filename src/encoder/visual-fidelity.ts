export interface RgbaFidelityMeasurement {
  meanAbsoluteError: { red: number; green: number; blue: number; alpha: number };
  rgbPsnrDb: number;
  maximumChannelError: number;
}

export function measureRgbaFidelity(
  original: Uint8Array,
  decoded: Uint8Array,
): RgbaFidelityMeasurement {
  if (original.byteLength !== decoded.byteLength || original.byteLength % 4 !== 0) {
    throw new Error('RGBA fidelity buffers must have equal four-channel lengths');
  }
  if (original.byteLength === 0) throw new Error('RGBA fidelity buffers must not be empty');
  const absolute = [0, 0, 0, 0];
  let rgbSquaredError = 0;
  let maximumChannelError = 0;
  for (let offset = 0; offset < original.byteLength; offset += 4) {
    for (let channel = 0; channel < 4; channel += 1) {
      const difference = Math.abs(
        (original[offset + channel] ?? 0) - (decoded[offset + channel] ?? 0),
      );
      absolute[channel] = (absolute[channel] ?? 0) + difference;
      maximumChannelError = Math.max(maximumChannelError, difference);
      if (channel < 3) rgbSquaredError += difference ** 2;
    }
  }
  const pixels = original.byteLength / 4;
  const meanSquaredError = rgbSquaredError / (pixels * 3);
  return {
    meanAbsoluteError: {
      red: (absolute[0] ?? 0) / pixels,
      green: (absolute[1] ?? 0) / pixels,
      blue: (absolute[2] ?? 0) / pixels,
      alpha: (absolute[3] ?? 0) / pixels,
    },
    rgbPsnrDb:
      meanSquaredError === 0
        ? Number.POSITIVE_INFINITY
        : 10 * Math.log10(255 ** 2 / meanSquaredError),
    maximumChannelError,
  };
}
