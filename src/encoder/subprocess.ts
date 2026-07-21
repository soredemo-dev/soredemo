import { spawn } from 'node:child_process';

export interface CapturedProcessResult {
  stdout: Buffer;
  stderr: Buffer;
  exitCode: number;
  signal: NodeJS.Signals | null;
}

export async function runCapturedProcess(options: {
  executable: string;
  arguments: readonly string[];
  maxOutputBytes?: number;
  timeoutMs?: number;
  stdin?: Uint8Array;
}): Promise<CapturedProcessResult> {
  const maxOutputBytes = options.maxOutputBytes ?? 16 * 1024 * 1024;
  const timeoutMs = options.timeoutMs ?? 15_000;
  return new Promise((resolve, reject) => {
    const child = spawn(options.executable, [...options.arguments], {
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let outputBytes = 0;
    let settled = false;
    const timeout = setTimeout(() => {
      child.kill('SIGKILL');
      finish(new Error(`Process timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    function finish(error?: Error, result?: CapturedProcessResult): void {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (error) reject(error);
      else if (result) resolve(result);
    }

    function collect(target: Buffer[], chunk: Buffer): void {
      outputBytes += chunk.byteLength;
      if (outputBytes > maxOutputBytes) {
        child.kill('SIGKILL');
        finish(new Error(`Process output exceeded ${maxOutputBytes} bytes`));
        return;
      }
      target.push(Buffer.from(chunk));
    }

    child.stdout.on('data', (chunk: Buffer) => collect(stdout, chunk));
    child.stderr.on('data', (chunk: Buffer) => collect(stderr, chunk));
    child.once('error', (error) => finish(error));
    child.once('close', (exitCode, signal) => {
      finish(undefined, {
        stdout: Buffer.concat(stdout),
        stderr: Buffer.concat(stderr),
        exitCode: exitCode ?? -1,
        signal,
      });
    });
    if (options.stdin) child.stdin.end(options.stdin);
    else child.stdin.end();
  });
}

export function requireSuccessfulProcess(
  result: CapturedProcessResult,
  description: string,
): CapturedProcessResult {
  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString('utf8').trim();
    throw new Error(
      `${description} failed with exit code ${result.exitCode}${stderr ? `: ${stderr}` : ''}`,
    );
  }
  return result;
}
