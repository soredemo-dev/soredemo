import { chmod, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { ClaudeCodeProvider } from '../../src/agent/claude-code-provider.js';

async function fakeClaude(root: string): Promise<string> {
  const file = resolve(root, 'fake-claude');
  await writeFile(
    file,
    `#!/usr/bin/env node
if (process.argv.includes('--version')) { console.log('2.1.217 (Claude Code)'); process.exit(0); }
let input = ''; process.stdin.setEncoding('utf8'); process.stdin.on('data', c => input += c);
process.stdin.on('end', () => {
  if (process.argv.includes('--dangerously-skip-permissions') || process.argv.some(a => input.includes(a) && a.includes('secret'))) process.exit(9);
  const proposal = {schemaVersion:1,title:'Create a project',summary:'A reviewed flow',assumptions:[],plan:{version:1,name:'agent-plan',url:'http://127.0.0.1:3000',intent:{goal:'Create a project'},actions:[{action:'click',target:{role:'button',name:'Create project'}}]},unresolved:[],warnings:[]};
  console.log(JSON.stringify({type:'result',result:JSON.stringify(proposal),session_id:'session-test'}));
});
`,
  );
  await chmod(file, 0o755);
  return file;
}

describe('Claude Code provider', () => {
  it('checks version and returns a validated structured proposal through read-only flags', async () => {
    const root = await mkdtemp(resolve(tmpdir(), 'soredemo-agent-'));
    const provider = new ClaudeCodeProvider(await fakeClaude(root), 5_000);
    await expect(provider.checkAvailability()).resolves.toMatchObject({
      available: true,
      version: '2.1.217 (Claude Code)',
    });
    const events = [];
    for await (const event of provider.proposePlan({
      conversationId: 'conversation-1',
      featureRequest: 'Show project creation',
      projectRoot: root,
      initialUrl: 'http://127.0.0.1:3000',
      consent: {
        sourceFiles: false,
        semanticSnapshot: false,
        existingPlansAndTests: false,
        screenshots: false,
      },
    })) {
      events.push(event);
    }
    expect(events.map((event) => event.type)).toEqual(['agent.started', 'agent.proposal']);
    expect(events[1]).toMatchObject({
      proposal: { plan: { actions: [{ action: 'click' }] } },
      sessionId: 'session-test',
    });
  });

  it('reports unavailable executables and makes cancellation idempotent', async () => {
    const provider = new ClaudeCodeProvider('/missing/soredemo-claude');
    await expect(provider.checkAvailability()).resolves.toMatchObject({ available: false });
    await expect(provider.cancel('missing')).resolves.toBeUndefined();
  });
});
