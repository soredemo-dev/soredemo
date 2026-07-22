#!/usr/bin/env node
import { formatRuntimeVersionFailure, runtimeVersionFailure } from './cli/runtime-version.js';

const argv = process.argv.slice(2);
const runtimeFailure = runtimeVersionFailure(process.versions.node);
if (runtimeFailure) {
  const json = argv.includes('--json') || argv.includes('--format=json');
  (json ? process.stdout : process.stderr).write(formatRuntimeVersionFailure(runtimeFailure, json));
  process.exitCode = 1;
} else {
  const { runCli } = await import('./cli/program.js');
  process.exitCode = await runCli(argv);
}
