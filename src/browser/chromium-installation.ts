import { constants } from 'node:fs';
import { access, readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { chromium } from 'playwright';

const require = createRequire(import.meta.url);

export interface ChromiumInstallation {
  installed: boolean;
  playwrightVersion: string;
  chromiumRevision: string;
  executablePath: string;
  browsersPath: string | null;
  installCommand: 'npx playwright install chromium';
  message?: string;
}

async function metadata(): Promise<{ playwrightVersion: string; chromiumRevision: string }> {
  const playwrightPackage = require.resolve('playwright/package.json');
  const packageJson = JSON.parse(await readFile(playwrightPackage, 'utf8')) as { version: string };
  const browsers = JSON.parse(
    await readFile(resolve(dirname(playwrightPackage), '../playwright-core/browsers.json'), 'utf8'),
  ) as { browsers: Array<{ name: string; revision: string }> };
  return {
    playwrightVersion: packageJson.version,
    chromiumRevision:
      browsers.browsers.find((browser) => browser.name === 'chromium')?.revision ?? 'unknown',
  };
}

export interface ChromiumInspectionOptions {
  executablePath?: string;
  versions?: { playwrightVersion: string; chromiumRevision: string };
  accessFile?: (path: string, mode: number) => Promise<void>;
  browsersPath?: string | null;
}

export async function inspectChromiumInstallation(
  options: ChromiumInspectionOptions = {},
): Promise<ChromiumInstallation> {
  const versions = options.versions ?? (await metadata());
  const executablePath = options.executablePath ?? chromium.executablePath();
  const browsersPath =
    options.browsersPath === undefined
      ? (process.env.PLAYWRIGHT_BROWSERS_PATH ?? null)
      : options.browsersPath;
  try {
    await (options.accessFile ?? access)(
      executablePath,
      process.platform === 'win32' ? constants.F_OK : constants.X_OK,
    );
    return {
      installed: true,
      ...versions,
      executablePath,
      browsersPath,
      installCommand: 'npx playwright install chromium',
    };
  } catch {
    return {
      installed: false,
      ...versions,
      executablePath,
      browsersPath,
      installCommand: 'npx playwright install chromium',
      message: `Playwright Chromium revision ${versions.chromiumRevision} is not installed. Run: npx playwright install chromium`,
    };
  }
}
