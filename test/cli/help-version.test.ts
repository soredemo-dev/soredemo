import { afterEach, describe, expect, it, vi } from 'vitest';
import { runCli } from '../../src/cli/program.js';

describe.sequential('public-alpha help and version', () => {
  afterEach(() => vi.restoreAllMocks());

  async function stdoutFor(args: string[]): Promise<string> {
    const output: string[] = [];
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk) => {
      output.push(String(chunk));
      return true;
    });
    expect(await runCli(args)).toBe(0);
    vi.restoreAllMocks();
    return output.join('');
  }

  it('prints only the package prerelease version', async () => {
    expect(await stdoutFor(['--version'])).toBe('0.1.0-alpha.1\n');
  });

  it('explains the alpha workflow at top level', async () => {
    const output = await stdoutFor(['--help']);
    expect(output).toContain('Soredemo public alpha');
    expect(output).toContain('Turn declarative YAML');
    expect(output).toContain('soredemo doctor');
    expect(output).toContain('soredemo render');
  });

  it.each(['validate', 'render', 'doctor', 'init', 'studio', 'proof'])(
    'shows %s-specific help',
    async (command) => {
      const output = await stdoutFor([command, '--help']);
      expect(output.toLowerCase()).toContain(command);
      expect(output).toContain('USAGE');
    },
  );
});
