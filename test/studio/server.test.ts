import { mkdtemp, readFile, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { applyProjectBootstrap, planProjectBootstrap } from '../../src/project/bootstrap.js';
import { startStudioServer } from '../../src/studio/server.js';

describe('Studio local server', () => {
  it('binds loopback, uses an HttpOnly session cookie, enforces origin, and removes its descriptor', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-studio-server-'));
    await applyProjectBootstrap(await planProjectBootstrap(root));
    const studio = await startStudioServer({ projectRoot: root, agent: 'none' });
    expect(studio.host).toBe('127.0.0.1');
    const page = await fetch(studio.url);
    expect(page.status).toBe(200);
    expect(page.headers.get('set-cookie')).toContain('HttpOnly');
    expect(await page.text()).toContain('Local only');
    const cookie = page.headers.get('set-cookie')?.split(';')[0] ?? '';
    const meta = await fetch(`${studio.url}/api/meta`, { headers: { cookie } });
    await expect(meta.json()).resolves.toMatchObject({
      product: 'Soredemo Studio',
      version: '0.1.0-alpha.1',
      localOnly: true,
    });
    const rejected = await fetch(`${studio.url}/api/snapshot`, {
      method: 'POST',
      headers: { cookie, origin: 'https://attacker.invalid', 'content-type': 'application/json' },
      body: '{}',
    });
    await expect(rejected.json()).resolves.toMatchObject({ code: 'STUDIO_ORIGIN_REJECTED' });
    const traversal = await fetch(`${studio.url}/api/plans/existing/approve`, {
      method: 'POST',
      headers: { cookie, origin: studio.url, 'content-type': 'application/json' },
      body: JSON.stringify({ path: '../private.yaml' }),
    });
    await expect(traversal.json()).resolves.toMatchObject({ code: 'STUDIO_PATH_INVALID' });
    const outside = resolve(root, '..', `outside-${process.pid}.yaml`);
    await writeFile(outside, 'private');
    await symlink(outside, resolve(root, 'demos/escaped.yaml'));
    const symlinkEscape = await fetch(`${studio.url}/api/plans/existing/approve`, {
      method: 'POST',
      headers: { cookie, origin: studio.url, 'content-type': 'application/json' },
      body: JSON.stringify({ path: 'demos/escaped.yaml' }),
    });
    await expect(symlinkEscape.json()).resolves.toMatchObject({ code: 'STUDIO_PATH_INVALID' });
    const unauthenticated = await fetch(`${studio.url}/api/meta`);
    expect(unauthenticated.status).toBe(401);
    expect(await readFile(resolve(root, '.soredemo/studio.json'), 'utf8')).not.toContain(
      'soredemo_session',
    );
    await studio.close();
    await expect(readFile(resolve(root, '.soredemo/studio.json'), 'utf8')).rejects.toThrow();
  });
});
