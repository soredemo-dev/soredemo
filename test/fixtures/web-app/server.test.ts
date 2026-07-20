import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import { startFixtureServer } from './server.js';

describe('deterministic web fixture', () => {
  it('provides a server helper and all controls required by the gate fixture', async () => {
    const html = await readFile('test/fixtures/web-app/index.html', 'utf8');
    const script = await readFile('test/fixtures/web-app/app.js', 'utf8');
    const styles = await readFile('test/fixtures/web-app/styles.css', 'utf8');

    expect(startFixtureServer).toBeTypeOf('function');
    expect(html).toContain('Preview analytics');
    expect(html).toContain('Growing hover target');
    expect(html).toContain('Project name');
    expect(html).toContain('Analytics');
    expect(html).toContain('Event log');
    expect(script).toContain("['pointerdown', 'pointerup', 'click']");
    expect(styles).toContain('position: sticky');
    expect(styles).toContain('.growing-button:hover');
  });
});
