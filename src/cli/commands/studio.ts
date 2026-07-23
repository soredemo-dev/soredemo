import { spawn } from 'node:child_process';
import { defineCommand } from 'citty';
import { CliExitError, EXIT_USAGE } from '../exit-codes.js';

export default defineCommand({
  meta: {
    name: 'studio',
    description: 'Open the local Soredemo Studio application',
  },
  args: {
    project: {
      type: 'string',
      description: 'project directory',
      default: '.',
    },
    host: {
      type: 'string',
      description: 'server host (loopback recommended)',
      default: '127.0.0.1',
    },
    port: {
      type: 'string',
      description: 'server port; omit for dynamic selection',
    },
    'no-open': {
      type: 'boolean',
      description: 'do not open the system browser',
      default: false,
    },
    agent: {
      type: 'enum',
      options: ['auto', 'claude-code', 'none'],
      description: 'optional Agent provider',
      default: 'auto',
    },
    json: {
      type: 'boolean',
      description: 'write one JSON startup value',
      default: false,
    },
  },
  async run({ args, rawArgs }) {
    const noOpen = args['no-open'] || rawArgs.includes('--no-open');
    const port = args.port === undefined ? 0 : Number(args.port);
    if (!Number.isInteger(port) || port < 0 || port > 65_535) {
      process.stderr.write('Studio port must be an integer from 0 through 65535.\n');
      throw new CliExitError(EXIT_USAGE);
    }
    const { startStudioServer } = await import('../../studio/server.js');
    const handle = await startStudioServer({
      projectRoot: args.project,
      host: args.host,
      port,
      agent: args.agent,
    });
    const loopback = ['127.0.0.1', '::1', 'localhost'].includes(handle.host);
    if (!loopback) {
      process.stderr.write(
        'Warning: Studio is bound beyond loopback. Remote hosting is unsupported; application pixels may be exposed.\n',
      );
    }
    const result = {
      success: true,
      url: handle.url,
      projectRoot: handle.projectRoot,
      host: handle.host,
      port: handle.port,
      pid: handle.pid,
      openedBrowser: !noOpen,
      agent: handle.agent,
    };
    if (args.json) process.stdout.write(`${JSON.stringify(result)}\n`);
    else {
      process.stdout.write(`Soredemo Studio: ${handle.url}\n`);
      process.stdout.write(`Project: ${handle.projectRoot}\n`);
      process.stdout.write(
        `Agent: ${handle.agent.displayName} (${handle.agent.available ? 'available' : 'manual mode'})\n`,
      );
    }
    if (!noOpen && process.platform === 'darwin') {
      const child = spawn('/usr/bin/open', [handle.url], {
        stdio: 'ignore',
        detached: true,
      });
      child.unref();
    }
    let closing = false;
    const close = async (): Promise<void> => {
      if (closing) return;
      closing = true;
      await handle.close();
    };
    const signal = (): void => {
      void close();
    };
    process.once('SIGINT', signal);
    process.once('SIGTERM', signal);
    try {
      await new Promise<void>((resolve) => {
        const interval = setInterval(() => {
          if (!closing) return;
          clearInterval(interval);
          resolve();
        }, 25);
      });
    } finally {
      process.off('SIGINT', signal);
      process.off('SIGTERM', signal);
      await close();
    }
  },
});
