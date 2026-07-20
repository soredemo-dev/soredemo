import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { ScriptInputSchema } from '../plan/input-schema.js';

export function generateJsonSchema(): Record<string, unknown> {
  return {
    $id: 'https://raw.githubusercontent.com/soredemo-dev/soredemo/main/schema/soredemo.schema.json',
    ...z.toJSONSchema(ScriptInputSchema, {
      target: 'draft-2020-12',
      io: 'input',
    }),
  };
}

export async function writeJsonSchema(rootDirectory = process.cwd()): Promise<void> {
  const schemaDirectory = resolve(rootDirectory, 'schema');
  await mkdir(schemaDirectory, { recursive: true });
  await writeFile(
    resolve(schemaDirectory, 'soredemo.schema.json'),
    `${JSON.stringify(generateJsonSchema(), null, 2)}\n`,
  );
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await writeJsonSchema();
}
