import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { load } from 'js-yaml';
import { loadProjectConfiguration } from '../src/config/load.js';
import { ScriptInputSchema } from '../src/plan/input-schema.js';

function fenced(markdown: string, name: string): string {
  const pattern = new RegExp(
    `<!-- ${name}:start -->\\s*\\n` +
      '```yaml\\n([\\s\\S]*?)\\n```\\s*\\n' +
      `<!-- ${name}:end -->`,
  );
  const value = pattern.exec(markdown)?.[1];
  if (!value) throw new Error(`README snippet ${name} is missing`);
  return `${value.trim()}\n`;
}

async function main(): Promise<void> {
  const readme = await readFile('README.md', 'utf8');
  const planFile = resolve('examples/quickstart/demos/create-project.yaml');
  const configFile = resolve('examples/quickstart/soredemo.config.yaml');
  const [plan, config] = await Promise.all([
    readFile(planFile, 'utf8'),
    readFile(configFile, 'utf8'),
  ]);
  if (fenced(readme, 'quickstart-plan') !== plan)
    throw new Error('README Demo Plan differs from its canonical example');
  if (fenced(readme, 'quickstart-config') !== config)
    throw new Error('README configuration differs from its canonical example');
  const parsed = ScriptInputSchema.safeParse(load(plan));
  if (!parsed.success) throw new Error(`README Demo Plan is invalid: ${parsed.error.message}`);
  await loadProjectConfiguration(planFile);
  process.stdout.write('README quickstart plan and configuration are synchronized and valid.\n');
}

await main();
