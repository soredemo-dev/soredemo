import { readdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

describe('Electron dependency boundary', () => {
  it('keeps the production engine free of any Electron import', () => {
    const root = resolve('src');
    const offenders = readdirSync(root, { recursive: true })
      .map((entry) => String(entry))
      .filter((entry) => entry.endsWith('.ts'))
      .filter((entry) =>
        /from\s+['"]electron(?:\/|['"])|require\(\s*['"]electron/u.test(
          readFileSync(resolve(root, entry), 'utf8'),
        ),
      );
    expect(offenders).toEqual([]);
  });
});
