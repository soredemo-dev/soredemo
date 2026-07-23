import { defineCommand } from 'citty';

const verify = defineCommand({
  meta: { name: 'verify', description: 'Verify a portable Soredemo proof bundle' },
  args: {
    directory: {
      type: 'positional',
      description: 'proof bundle directory',
      required: true,
    },
    json: {
      type: 'boolean',
      description: 'write one JSON result',
      default: false,
    },
  },
  async run({ args }) {
    const { verifyProofBundle } = await import('../../proof/verify-proof.js');
    const result = await verifyProofBundle(args.directory);
    if (args.json) process.stdout.write(`${JSON.stringify(result)}\n`);
    else process.stdout.write(`✓ Verified ${result.proofLevel} proof bundle\n`);
  },
});

export default defineCommand({
  meta: { name: 'proof', description: 'Inspect portable proof artifacts' },
  subCommands: { verify },
});
