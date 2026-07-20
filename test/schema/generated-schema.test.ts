import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import { generateJsonSchema } from '../../src/schema/generate-json-schema.js';

describe('generated JSON Schema', () => {
  it('matches the checked-in draft 2020-12 artifact', async () => {
    const checkedIn = JSON.parse(await readFile('schema/soredemo.schema.json', 'utf8'));

    expect(generateJsonSchema()).toEqual(checkedIn);
    expect(checkedIn.$schema).toBe('https://json-schema.org/draft/2020-12/schema');
  });
});
