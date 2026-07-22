import { describe, expect, it } from 'vitest';
import { inspectChromiumInstallation } from '../../src/browser/chromium-installation.js';

const versions = { playwrightVersion: '1.61.1', chromiumRevision: '1228' };

describe('Chromium installation diagnostics', () => {
  it('reports an installed executable', async () => {
    const result = await inspectChromiumInstallation({
      executablePath: '/cache/chromium',
      versions,
      accessFile: async () => undefined,
      browsersPath: '/cache',
    });
    expect(result).toMatchObject({ installed: true, browsersPath: '/cache', ...versions });
  });

  it('reports exact remediation when the executable is absent', async () => {
    const result = await inspectChromiumInstallation({
      executablePath: '/empty/chromium',
      versions,
      accessFile: async () => {
        throw new Error('missing');
      },
      browsersPath: '/empty',
    });
    expect(result).toMatchObject({
      installed: false,
      executablePath: '/empty/chromium',
      browsersPath: '/empty',
      installCommand: 'npx playwright install chromium',
    });
    expect(result.message).toContain('revision 1228');
    expect(result.message).toContain('npx playwright install chromium');
  });
});
