import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { hasFastStart, readTopLevelMp4Boxes } from '../../src/encoder/mp4-boxes.js';

function box(type: string, payload = Buffer.alloc(0)): Buffer {
  const header = Buffer.alloc(8);
  header.writeUInt32BE(header.byteLength + payload.byteLength, 0);
  header.write(type, 4, 4, 'ascii');
  return Buffer.concat([header, payload]);
}

function extendedBox(type: string, payload = Buffer.alloc(0)): Buffer {
  const header = Buffer.alloc(16);
  header.writeUInt32BE(1, 0);
  header.write(type, 4, 4, 'ascii');
  header.writeBigUInt64BE(BigInt(header.byteLength + payload.byteLength), 8);
  return Buffer.concat([header, payload]);
}

describe('top-level MP4 boxes', () => {
  it('reads 32-bit and extended boxes and validates fast start', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'soredemo-mp4-boxes-'));
    const file = join(directory, 'fast.mp4');
    await writeFile(file, Buffer.concat([box('ftyp'), extendedBox('moov'), box('mdat')]));
    const boxes = await readTopLevelMp4Boxes(file);
    expect(boxes.map((item) => item.type)).toEqual(['ftyp', 'moov', 'mdat']);
    expect(hasFastStart(boxes)).toBe(true);
  });

  it('detects non-fast-start and missing boxes', () => {
    expect(
      hasFastStart([
        { type: 'mdat', offset: 0, size: 8 },
        { type: 'moov', offset: 8, size: 8 },
      ]),
    ).toBe(false);
    expect(() => hasFastStart([{ type: 'moov', offset: 0, size: 8 }])).toThrow('moov and mdat');
  });

  it('rejects malformed short and out-of-bounds sizes', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'soredemo-mp4-invalid-'));
    const short = Buffer.alloc(8);
    short.writeUInt32BE(4, 0);
    short.write('moov', 4, 4, 'ascii');
    const file = join(directory, 'invalid.mp4');
    await writeFile(file, short);
    await expect(readTopLevelMp4Boxes(file)).rejects.toThrow('Invalid MP4 box size');

    const oversized = Buffer.alloc(8);
    oversized.writeUInt32BE(100, 0);
    oversized.write('mdat', 4, 4, 'ascii');
    await writeFile(file, oversized);
    await expect(readTopLevelMp4Boxes(file)).rejects.toThrow('file bounds');
  });
});
