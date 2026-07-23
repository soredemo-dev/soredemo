import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { JSON_SCHEMA, load, YAMLException } from 'js-yaml';
import { DemoPlanFileError, DemoPlanSyntaxError, DemoPlanValidationError } from './errors.js';
import { ScriptInputSchema } from './input-schema.js';
import { normalizeScript } from './normalize.js';
import type { ActionPlan } from './normalized-plan.js';

export async function loadDemoPlan(scriptPath: string): Promise<ActionPlan> {
  const absolutePath = resolve(scriptPath);
  let source: string;

  try {
    source = await readFile(absolutePath, 'utf8');
  } catch (error) {
    throw new DemoPlanFileError(`Unable to read demo plan: ${scriptPath}`, error);
  }

  let input: unknown;
  try {
    input = load(source, { schema: JSON_SCHEMA });
  } catch (error) {
    const detail = error instanceof YAMLException ? error.reason : 'Unable to parse YAML';
    throw new DemoPlanSyntaxError(`Invalid YAML: ${detail}`, error);
  }

  return parseDemoPlan(input);
}

export function parseDemoPlan(input: unknown): ActionPlan {
  const result = ScriptInputSchema.safeParse(input);
  if (!result.success) {
    throw new DemoPlanValidationError(result.error.issues, input);
  }

  return normalizeScript(result.data);
}
