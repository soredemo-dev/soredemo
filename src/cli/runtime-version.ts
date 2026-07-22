export const SUPPORTED_NODE_RANGE = '>=20.19.4 <21';

export interface RuntimeVersionFailure {
  code: 'UNSUPPORTED_NODE_VERSION';
  message: string;
  currentVersion: string;
  requiredRange: string;
}

function parseVersion(value: string): [number, number, number] | null {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(value);
  if (!match) return null;
  const parts = match.slice(1, 4).map(Number);
  if (parts.some((part) => !Number.isSafeInteger(part))) return null;
  return [parts[0] ?? 0, parts[1] ?? 0, parts[2] ?? 0];
}

export function runtimeVersionFailure(version: string): RuntimeVersionFailure | null {
  const parsed = parseVersion(version);
  const supported =
    parsed !== null && parsed[0] === 20 && (parsed[1] > 19 || (parsed[1] === 19 && parsed[2] >= 4));
  if (supported) return null;
  return {
    code: 'UNSUPPORTED_NODE_VERSION',
    message:
      'Soredemo public alpha currently requires Node.js 20.19.4 or later within the Node 20 release line.',
    currentVersion: version,
    requiredRange: SUPPORTED_NODE_RANGE,
  };
}

export function formatRuntimeVersionFailure(failure: RuntimeVersionFailure, json: boolean): string {
  if (json) return `${JSON.stringify({ success: false, ...failure })}\n`;
  return `${failure.message}\n\nCurrent runtime:\n  Node.js ${failure.currentVersion}\n`;
}
