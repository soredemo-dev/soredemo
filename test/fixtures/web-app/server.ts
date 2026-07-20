import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const fixtureDirectory = dirname(fileURLToPath(import.meta.url));

const assets = new Map([
  ['/app.js', { file: 'app.js', contentType: 'text/javascript; charset=utf-8' }],
  ['/styles.css', { file: 'styles.css', contentType: 'text/css; charset=utf-8' }],
]);

export interface FixtureServer {
  url: string;
  close(): Promise<void>;
}

export async function startFixtureServer(
  port = 0,
  rootDirectory = fixtureDirectory,
): Promise<FixtureServer> {
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname;
    const asset = assets.get(pathname) ?? {
      file: 'index.html',
      contentType: 'text/html; charset=utf-8',
    };

    try {
      const body = await readFile(join(rootDirectory, asset.file));
      response.writeHead(200, { 'content-type': asset.contentType });
      response.end(body);
    } catch {
      response.writeHead(500);
      response.end('Fixture asset unavailable');
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });

  const address = server.address();
  if (address === null || typeof address === 'string') {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    throw new Error('Fixture server did not bind a TCP port');
  }

  return {
    url: `http://127.0.0.1:${address.port}`,
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      ),
  };
}
