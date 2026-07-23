import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';

describe('Studio UI structure', () => {
  it('provides accessible chat, preview, plan, evidence, privacy, and stop controls', async () => {
    const html = await readFile('studio/public/index.html', 'utf8');
    expect(html).toContain('AI Chat');
    expect(html).toContain('Application preview');
    expect(html).toContain('Demo Plan');
    expect(html).toContain('Run and evidence');
    expect(html).toContain('Local only');
    expect(html).toContain('Live capture preview — final output is rendered separately');
    expect(html).toContain('aria-live');
    expect(html).toContain('Stop recording');
    expect(html).toContain('Validate edited JSON');
    expect(html).toContain('<video');
  });
});
