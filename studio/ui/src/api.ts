// Same-origin Studio API client. The session cookie is set by the server on the
// initial document load and sent automatically; no tokens are handled here and
// no remote origins are ever contacted.
export class ApiError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(path, {
    ...options,
    headers: {
      'content-type': 'application/json',
      ...(options.headers ?? {}),
    },
  });
  const value = (await response.json()) as Record<string, unknown>;
  if (!response.ok) {
    throw new ApiError(
      typeof value.code === 'string' ? value.code : 'STUDIO_ERROR',
      typeof value.message === 'string' ? value.message : 'Request failed',
    );
  }
  return value as T;
}

export function artifactUrl(id: string): string {
  return `/api/artifacts/${id}`;
}
