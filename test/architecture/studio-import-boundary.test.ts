import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

describe('Studio lazy import boundary', () => {
  it('loads Studio and Agent modules only when the studio command runs', () => {
    const program = readFileSync('src/cli/program.ts', 'utf8');
    const startup = readFileSync('src/cli.ts', 'utf8');
    const studio = readFileSync('src/cli/commands/studio.ts', 'utf8');
    expect(program).toContain("studio: () => import('./commands/studio.js')");
    expect(startup).not.toContain('studio/');
    expect(studio).not.toMatch(/^import .*studio\/server/mu);
    expect(studio).toContain("await import('../../studio/server.js')");
  });

  it('keeps validation independent of Agent, Studio, and proof modules', () => {
    const validation = readFileSync('src/cli/commands/validate.ts', 'utf8');
    expect(validation).not.toMatch(/agent|studio|proof/u);
  });
});
