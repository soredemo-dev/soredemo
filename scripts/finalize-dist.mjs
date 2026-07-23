import { chmod, cp } from 'node:fs/promises';

await chmod(new URL('../dist/cli.js', import.meta.url), 0o755);
await cp(
  new URL('../studio/public', import.meta.url),
  new URL('../dist/studio/public', import.meta.url),
  {
    recursive: true,
  },
);
