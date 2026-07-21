import { startFixtureServer } from '../test/fixtures/web-app/server.js';

const port = Number(process.argv[2] ?? 4173);
const server = await startFixtureServer(port);
process.stdout.write(`${JSON.stringify({ url: server.url })}\n`);

let closing = false;
const close = async () => {
  if (closing) return;
  closing = true;
  await server.close();
};
process.once('SIGINT', () => void close());
process.once('SIGTERM', () => void close());
await new Promise<void>((resolve) => {
  process.once('SIGINT', resolve);
  process.once('SIGTERM', resolve);
});
