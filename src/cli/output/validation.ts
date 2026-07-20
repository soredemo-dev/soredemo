import type { ZodIssue } from 'zod';
import type { DemoPlanValidationError } from '../../plan/errors.js';

export interface ValidationDiagnostic {
  path: Array<string | number>;
  code: string;
  expected: string;
  received: string;
  message: string;
}

function valueAtPath(input: unknown, path: Array<string | number>): unknown {
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

function normalizePath(path: PropertyKey[]): Array<string | number> {
  return path.map((segment) => (typeof segment === 'symbol' ? String(segment) : segment));
}

function unionBranchScore(issues: ZodIssue[]): number {
  const discriminatorMismatches = issues.filter(
    (issue) => issue.path.at(-1) === 'action' && issue.code === 'invalid_value',
  ).length;
  return discriminatorMismatches * 100 + issues.length;
}

function diagnosticsForIssue(
  issue: ZodIssue,
  input: unknown,
  prefix: Array<string | number>,
): ValidationDiagnostic[] {
  const path = [...prefix, ...normalizePath(issue.path)];
  if (issue.code === 'invalid_union') {
    const received = valueAtPath(input, path);
    if (received === undefined || received === null || typeof received !== 'object') {
      return [
        {
          path,
          code: 'invalid_type',
          expected: 'object',
          received: describeValue(received),
          message: 'Required',
        },
      ];
    }

    const branch = [...issue.errors].sort(
      (left, right) => unionBranchScore(left) - unionBranchScore(right),
    )[0];
    if (branch) {
      return branch.flatMap((nestedIssue) => diagnosticsForIssue(nestedIssue, input, path));
    }
  }

  return [
    {
      path,
      code: issue.code,
      expected: expectedForIssue(issue),
      received: describeValue(valueAtPath(input, path)),
      message: issue.message,
    },
  ];
}

export function validationDiagnostics(error: DemoPlanValidationError): ValidationDiagnostic[] {
  return error.issues.flatMap((issue) => diagnosticsForIssue(issue, error.input, []));
}

export function formatValidationJson(error: DemoPlanValidationError): string {
  return `${JSON.stringify({ valid: false, errors: validationDiagnostics(error) }, null, 2)}\n`;
}

function formatPath(path: Array<string | number>): string {
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
