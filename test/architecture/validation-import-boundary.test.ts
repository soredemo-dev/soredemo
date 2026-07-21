import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const forbidden =
  /^(node:child_process|playwright(?:-core)?|@napi-rs\/canvas|bezier-easing)$|(?:^|\/)(?:chromium|capture|resample|compositor|studio|camera|cursor|click-feedback|encoder)(?:\/|$)/;

function importsFrom(file: string, includeDynamicImports: boolean): string[] {
  const source = readFileSync(file, 'utf8');
  const staticImports = [
    ...source.matchAll(/(?:import|export)\s+(?:type\s+)?(?:[^'";]*?\sfrom\s*)?['"]([^'"]+)['"]/g),
  ]
    .map((match) => match[1])
    .filter((specifier) => specifier !== undefined);
  if (!includeDynamicImports) return staticImports;

  const dynamicImports = [...source.matchAll(/import\(\s*['"]([^'"]+)['"]\s*\)/g)]
    .map((match) => match[1])
    .filter((specifier) => specifier !== undefined);
  return [...staticImports, ...dynamicImports];
}

function reachableImports(entry: string, includeDynamicImports: boolean): string[] {
  const visited = new Set<string>();
  const imports = new Set<string>();

  function visit(file: string): void {
    if (visited.has(file)) return;
    visited.add(file);
    for (const specifier of importsFrom(file, includeDynamicImports)) {
      imports.add(specifier);
      if (!specifier.startsWith('.')) continue;
      const resolved = resolve(dirname(file), specifier.replace(/\.js$/, '.ts'));
      if (existsSync(resolved)) visit(resolved);
    }
  }

  visit(resolve(entry));
  return [...imports];
}

describe('validation import boundary', () => {
  it('keeps startup and validation imports free of rendering dependencies', () => {
    const startupImports = reachableImports('src/cli.ts', false);
    const validationImports = reachableImports('src/cli/commands/validate.ts', true);
    const violatingImports = [...startupImports, ...validationImports].filter((specifier) =>
      forbidden.test(specifier),
    );

    expect(violatingImports).toEqual([]);
  });
});
