import { afterEach, describe, expect, it, vi } from 'vitest';
import { runCli } from '../../src/cli/program.js';

describe.sequential('render command', () => {
  afterEach(() => vi.restoreAllMocks());

  it('rejects an invalid plan before entering the render pipeline', async () => {
    const stdout: string[] = [];
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk) => {
      stdout.push(String(chunk));
      return true;
    });
    vi.spyOn(process.stderr, 'write').mockImplementation(() => true);

    const exitCode = await runCli(['render', 'test/fixtures/invalid-demo.yaml', '--json']);

    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout.join(''))).toMatchObject({
      success: false,
      code: 'PLAN_INVALID',
      stage: 'validating',
    });
  });

  it('reports render CLI misuse as exit 2', async () => {
    const stderr: string[] = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk) => {
      stderr.push(String(chunk));
      return true;
    });

    const exitCode = await runCli(['render', 'examples/demo.yaml', '--unknown']);

    expect(exitCode).toBe(2);
    expect(stderr.join('')).toContain('Unknown option');
  });

  it('rejects incompatible reporter flags as exit 2', async () => {
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const stderr: string[] = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk) => {
      stderr.push(String(chunk));
      return true;
    });

    expect(await runCli(['render', 'examples/demo.yaml', '--quiet', '--verbose'])).toBe(2);
    expect(stderr.join('')).toContain('Use only one');
  });
});
