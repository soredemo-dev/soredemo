import { afterEach, describe, expect, it, vi } from 'vitest';
import { RenderReporter } from '../../src/cli/output/render-reporter.js';
import { RenderError } from '../../src/render/errors.js';

function output() {
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

describe('render reporter', () => {
  afterEach(() => vi.restoreAllMocks());

  it('keeps JSON stdout to one final value', () => {
    const captured = output();
    const reporter = new RenderReporter('json');
    reporter.stage({ stage: 'capturing', status: 'completed', message: 'Captured' });
    reporter.diagnostic('details', { secret: 'not written in json mode' });
    reporter.success({ outputPath: '/tmp/demo.mp4', success: true });
    expect(captured.stdout).toHaveLength(1);
    expect(JSON.parse(captured.stdout[0] ?? '')).toEqual({
      outputPath: '/tmp/demo.mp4',
      success: true,
    });
  });

  it('suppresses stages in quiet mode but retains warnings and final result', () => {
    const captured = output();
    const reporter = new RenderReporter('quiet');
    reporter.stage({ stage: 'capturing', status: 'completed', message: 'Captured' });
    reporter.warning({ code: 'CAPTURE_VERSION_SENSITIVE', message: 'Pinned path' });
    reporter.success({ outputPath: '/tmp/demo.mp4' });
    expect(captured.stdout.join('')).toBe('Created /tmp/demo.mp4\n');
    expect(captured.stderr.join('')).toContain('CAPTURE_VERSION_SENSITIVE');
    expect(captured.stderr.join('')).not.toContain('Captured');
  });

  it('prints bounded failures without stacks', () => {
    const captured = output();
    new RenderReporter('human').failure(
      new RenderError({
        code: 'TARGET_NOT_FOUND',
        stage: 'capturing',
        message: 'Could not find target',
        actionIndex: 4,
        actionKind: 'click',
        targetDescription: 'role=button, name="Create project"',
      }),
    );
    expect(captured.stderr.join('')).toContain('Action 4 (click)');
    expect(captured.stderr.join('')).not.toContain('RenderError');
    expect(captured.stderr.join('')).not.toContain(' at ');
  });
});
