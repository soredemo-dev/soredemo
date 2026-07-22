import { readFileSync } from 'node:fs';

export interface PackageMetadata {
  name: string;
  version: string;
}

let cached: PackageMetadata | undefined;

export function packageMetadata(): PackageMetadata {
  if (cached) return cached;
  const parsed = JSON.parse(
    readFileSync(new URL('../../package.json', import.meta.url), 'utf8'),
  ) as Partial<PackageMetadata>;
  if (parsed.name !== 'soredemo' || typeof parsed.version !== 'string') {
    throw new Error('Installed Soredemo package metadata is invalid');
  }
  cached = { name: parsed.name, version: parsed.version };
  return cached;
}
