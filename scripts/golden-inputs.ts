import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createCanvas } from '@napi-rs/canvas';
import { hashCanonicalInputs } from '../test/golden-tools/input-hashes.js';
import { stableJson } from '../test/golden-tools/profile.js';

const root = resolve('test/golden-input/studio-v1');
const sourceRoot = resolve(root, 'source-frames');

if (!process.argv.includes('--confirm')) {
  throw new Error('Canonical input replacement requires --confirm');
}

await mkdir(sourceRoot, { recursive: true });
for (const definition of [
  { file: 'establish.png', accent: '#7c3aed', panel: '#ede9fe', marker: 120 },
  { file: 'hover.png', accent: '#2563eb', panel: '#dbeafe', marker: 360 },
  { file: 'form.png', accent: '#0f766e', panel: '#ccfbf1', marker: 600 },
  { file: 'scrolled.png', accent: '#c2410c', panel: '#ffedd5', marker: 840 },
  { file: 'result.png', accent: '#15803d', panel: '#dcfce7', marker: 1080 },
] as const) {
  const canvas = createCanvas(2880, 1800);
  const context = canvas.getContext('2d');
  context.fillStyle = '#ffffff';
  context.fillRect(0, 0, 2880, 1800);
  context.fillStyle = '#f8fafc';
  context.fillRect(0, 0, 2880, 160);
  context.fillStyle = definition.accent;
  context.fillRect(0, 0, 28, 1800);
  context.fillRect(96, 88, 520, 28);
  context.fillStyle = definition.panel;
  context.fillRect(160, 260, 2560, 1180);
  context.fillStyle = definition.accent;
  context.fillRect(definition.marker, 420, 420, 140);
  context.fillRect(1220, 800, 440, 120);
  context.fillRect(160, 1380, 520, 120);
  context.fillStyle = '#0f172a';
  for (let index = 0; index < 9; index += 1) {
    context.fillRect(220, 660 + index * 62, 900 + index * 90, 14);
  }
  context.fillStyle = '#ffffff';
  context.fillRect(1270, 836, 340, 48);
  await writeFile(resolve(sourceRoot, definition.file), canvas.toBuffer('image/png'));
}

const manifestPath = resolve(root, 'manifest.json');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8')) as Record<string, unknown>;
const files = [
  'camera-track.json',
  'resample-plan.jsonl',
  'timeline.json',
  'source-frames/establish.png',
  'source-frames/form.png',
  'source-frames/hover.png',
  'source-frames/result.png',
  'source-frames/scrolled.png',
];
manifest.files = await hashCanonicalInputs(root, files);
await writeFile(manifestPath, stableJson(manifest));
console.log(`Wrote ${files.length} canonical compositor inputs under ${root}`);
