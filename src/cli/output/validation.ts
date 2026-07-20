import type { ZodIssue } from 'zod';
import type { DemoPlanValidationError } from '../../plan/errors.js';

export interface ValidationDiagnostic {
  path: PropertyKey[];
  code: string;
  expected: string;
  received: string;
  message: string;
}

function valueAtPath(input: unknown, path: PropertyKey[]): unknown {
  let value = input;
  for (const segment of path) {
    if (value === null || value === undefined || typeof value !== 'object') return undefined;
    value = (value as Record<PropertyKey, unknown>)[segment];
  }
  return value;
}

function describeValue(value: unknown): string {
  if (value === undefined) return 'undefined';
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}

function expectedForIssue(issue: ZodIssue): string {
  if ('expected' in issue && typeof issue.expected === 'string') return issue.expected;
  if (issue.code === 'invalid_union') return 'valid union member';
  if (issue.code === 'unrecognized_keys') return 'known properties only';
  return 'valid value';
}

function flattenIssue(issue: ZodIssue): ZodIssue[] {
  if (issue.code !== 'invalid_union') return [issue];
  const nested = issue.errors.flat();
  if (nested.length === 0) return [issue];
  const deepestPathLength = Math.max(...nested.map((candidate) => candidate.path.length));
  return nested.filter((candidate) => candidate.path.length === deepestPathLength);
}

export function validationDiagnostics(error: DemoPlanValidationError): ValidationDiagnostic[] {
  return error.issues.flatMap(flattenIssue).map((issue) => {
    const path = [...issue.path];
    return {
      path,
      code: issue.code,
      expected: expectedForIssue(issue),
      received: describeValue(valueAtPath(error.input, path)),
      message: issue.message,
    };
  });
}

export function formatValidationJson(error: DemoPlanValidationError): string {
  return `${JSON.stringify({ valid: false, errors: validationDiagnostics(error) }, null, 2)}\n`;
}

function formatPath(path: PropertyKey[]): string {
  return path.reduce<string>((result, segment) => {
    if (typeof segment === 'number') return `${result}[${segment}]`;
    return result === '' ? String(segment) : `${result}.${String(segment)}`;
  }, '');
}

export function formatValidationHuman(error: DemoPlanValidationError): string {
  const details = validationDiagnostics(error)
    .map(
      (diagnostic) =>
        `${formatPath(diagnostic.path) || '<root>'}\n  Expected: ${diagnostic.expected}\n  Received: ${diagnostic.received}`,
    )
    .join('\n\n');
  return `Invalid demo plan\n\n${details}\n`;
}
