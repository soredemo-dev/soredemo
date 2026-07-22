import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
  GOLDEN_CANDIDATE_ROOT,
  generateExactCandidate,
} from '../test/golden-tools/exact-authority.js';
import {
  promoteCandidate,
  verifyCandidate,
  verifyCheckedGoldens,
} from '../test/golden-tools/golden-workflow.js';
import {
  inspectExactProfile,
  requireOfficialExactProfile,
  stableJson,
} from '../test/golden-tools/profile.js';

const execFileAsync = promisify(execFile);
const command = process.argv[2];

if (command === 'generate') {
  requireOfficialExactProfile(await inspectExactProfile());
  if (!process.argv.includes('--allow-dirty')) {
    const { stdout } = await execFileAsync('git', ['status', '--porcelain']);
    if (stdout.trim())
      throw new Error('Golden generation requires a clean worktree (or --allow-dirty)');
  }
  const result = await generateExactCandidate();
  console.log(
    stableJson({
      success: true,
      candidatePath: GOLDEN_CANDIDATE_ROOT,
      frameCount: result.manifest.frames.length,
      contactSheet: result.contactSheetFile,
    }),
  );
} else if (command === 'verify-candidate') {
  console.log(stableJson(await verifyCandidate()));
} else if (command === 'promote') {
  await promoteCandidate(process.argv.includes('--confirm'));
  console.log(stableJson({ success: true, promoted: true }));
} else if (command === 'verify') {
  console.log(stableJson(await verifyCheckedGoldens()));
} else {
  throw new Error('Expected generate, verify-candidate, promote, or verify');
}
