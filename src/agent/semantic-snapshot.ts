import { chromium } from 'playwright';
import type { SemanticApplicationSnapshot } from './types.js';

export async function inspectSemanticApplication(options: {
  url: string;
  maxElements?: number;
  maxTextCharacters?: number;
}): Promise<SemanticApplicationSnapshot> {
  const url = new URL(options.url);
  if (url.protocol !== 'http:' && url.protocol !== 'https:')
    throw new Error('Snapshot URL must use HTTP or HTTPS');
  const maxElements = Math.min(Math.max(options.maxElements ?? 200, 1), 500);
  const maxTextCharacters = Math.min(Math.max(options.maxTextCharacters ?? 4_000, 100), 10_000);
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({
      viewport: { width: 1440, height: 900 },
      deviceScaleFactor: 2,
    });
    await page.goto(url.href, { waitUntil: 'domcontentloaded', timeout: 30_000 });
    const collected = await page.evaluate(
      ({ maxElements, maxTextCharacters }) => {
        const candidates = [
          ...document.querySelectorAll<HTMLElement>(
            'button,input,textarea,select,a,[role],[data-testid],[aria-label]',
          ),
        ];
        const visible = candidates.filter((element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return (
            rect.width > 0 &&
            rect.height > 0 &&
            style.visibility !== 'hidden' &&
            style.display !== 'none'
          );
        });
        const elements = visible.slice(0, maxElements).map((element) => {
          const rect = element.getBoundingClientRect();
          const label =
            element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
              ? element.labels?.[0]?.textContent?.trim()
              : undefined;
          const name =
            element.getAttribute('aria-label') ?? element.textContent?.trim().slice(0, 160);
          const role = element.getAttribute('role');
          return {
            tag: element.tagName.toLowerCase(),
            ...(role ? { role } : {}),
            ...(name ? { name } : {}),
            ...(label ? { label } : {}),
            ...(element.dataset.testid ? { testId: element.dataset.testid } : {}),
            rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          };
        });
        const bodyText = (document.body.innerText || '').replace(/\s+/gu, ' ').trim();
        return {
          elements,
          visibleTextSummary: bodyText.slice(0, maxTextCharacters),
          truncated: visible.length > maxElements || bodyText.length > maxTextCharacters,
        };
      },
      { maxElements, maxTextCharacters },
    );
    return {
      schemaVersion: 1,
      url: page.url(),
      title: await page.title(),
      viewport: { width: 1440, height: 900 },
      ...collected,
    };
  } finally {
    await browser.close();
  }
}
