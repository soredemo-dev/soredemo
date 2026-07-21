import { open } from 'node:fs/promises';

export interface Mp4Box {
  type: string;
  offset: number;
  size: number;
}

function parseSize32(buffer: Buffer): number {
  return buffer.readUInt32BE(0);
}

export async function readTopLevelMp4Boxes(file: string): Promise<Mp4Box[]> {
  const handle = await open(file, 'r');
  try {
    const fileSize = (await handle.stat()).size;
    const boxes: Mp4Box[] = [];
    let offset = 0;
    while (offset < fileSize) {
      const header = Buffer.alloc(16);
      const { bytesRead } = await handle.read(header, 0, 8, offset);
      if (bytesRead !== 8) throw new Error('Truncated MP4 box header');
      const size32 = parseSize32(header);
      const type = header.toString('ascii', 4, 8);
      let size: number;
      if (size32 === 1) {
        const extended = await handle.read(header, 8, 8, offset + 8);
        if (extended.bytesRead !== 8) throw new Error('Truncated extended MP4 box header');
        const value = header.readBigUInt64BE(8);
        if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('MP4 box is too large');
        size = Number(value);
        if (size < 16) throw new Error('Invalid extended MP4 box size');
      } else if (size32 === 0) {
        size = fileSize - offset;
      } else {
        size = size32;
        if (size < 8) throw new Error('Invalid MP4 box size');
      }
      if (offset + size > fileSize) throw new Error('MP4 box exceeds file bounds');
      boxes.push({ type, offset, size });
      offset += size;
    }
    return boxes;
  } finally {
    await handle.close();
  }
}

export function hasFastStart(boxes: readonly Mp4Box[]): boolean {
  const moov = boxes.findIndex((box) => box.type === 'moov');
  const mdat = boxes.findIndex((box) => box.type === 'mdat');
  if (moov < 0 || mdat < 0) throw new Error('MP4 must contain moov and mdat boxes');
  return moov < mdat;
}
