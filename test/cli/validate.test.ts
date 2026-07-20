import { afterEach, describe, expect, it, vi } from 'vitest';
import { runCli } from '../../src/cli/program.js';

function captureOutput() {
  const stdout: string[] = [];
  const stderr: string[] = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk) => {
    stdout.push(String(chunk));
    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation((chunk) => {
    stderr.push(String(chunk));
    return true;
  });
  return { stdout, stderr };
}

describe.sequential('validate command', () => {
  afterEach(() => vi.restoreAllMocks());

  it('exits 0 for a valid plan', async () => {
    const output = captureOutput();
    const exitCode = await runCli(['validate', 'examples/demo.yaml']);

    expect(exitCode).toBe(0);
    expect(output.stdout.join('')).toBe('Valid demo plan: create-project\n');
    expect(output.stderr).toEqual([]);
  });

  it('exits 1 with parseable JSON for an invalid plan', async () => {
    const output = captureOutput();
    const exitCode = await runCli(['validate', 'test/fixtures/invalid-demo.yaml', '--format=json']);

    expect(exitCode).toBe(1);
    expect(JSON.parse(output.stdout.join('')).errors[0].path).toEqual(['actions', 0, 'target']);
    expect(output.stderr).toEqual([]);
  });

  it('exits 2 for missing arguments and unknown options', async () => {
    const missingOutput = captureOutput();
    expect(await runCli(['validate'])).toBe(2);
    expect(missingOutput.stderr.join('')).toContain('Missing required positional argument');
    vi.restoreAllMocks();

    const unknownOutput = captureOutput();
    expect(await runCli(['validate', 'examples/demo.yaml', '--wat'])).toBe(2);
    expect(unknownOutput.stderr.join('')).toContain('Unknown option: --wat');
  });
});
