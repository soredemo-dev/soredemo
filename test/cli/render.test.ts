import { afterEach, describe, expect, it, vi } from 'vitest';
import { runCli } from '../../src/cli/program.js';

describe.sequential('render command', () => {
  afterEach(() => vi.restoreAllMocks());

  it('validates the plan and reports the Day-1 boundary as exit 1', async () => {
    const stderr: string[] = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk) => {
      stderr.push(String(chunk));
      return true;
    });

    const exitCode = await runCli([
      'render',
      'examples/demo.yaml',
      '--out',
      'demo.mp4',
      '--verbose',
    ]);

    expect(exitCode).toBe(1);
    expect(stderr.join('')).toContain('Requested output: demo.mp4');
    expect(stderr.join('')).toContain('not implemented on Day 1');
  });
});
