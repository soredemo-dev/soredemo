import { setTimeout } from 'node:timers/promises';
import { createCanvas, loadImage } from '@napi-rs/canvas';
import type { BrowserContext, Page } from 'playwright';
import { RenderError } from '../render/errors.js';
import type { CapturePixelScaleProof, CdpLayoutMetrics } from './types.js';

const PROBE_ID = 'soredemo-capture-scale-proof';
const CSS_SIZE = 32;
const COLORS = [
  [255, 0, 0],
  [0, 255, 0],
  [0, 0, 255],
  [255, 255, 0],
] as const;

export function assertCapturePixelScaleProof(proof: CapturePixelScaleProof): void {
  if (proof.passed) return;
  throw new RenderError({
    code: 'CAPTURE_PIXEL_SCALE_INVALID',
    stage: 'preparing-page',
    message: 'Chromium screencast pixels do not match the configured device scale',
    details: proof as unknown as Record<string, unknown>,
  });
}

export async function verifyCapturePixelScale(options: {
  context: BrowserContext;
  page: Page;
  viewport: { width: number; height: number };
  deviceScaleFactor: number;
  expectedPixelWidth: number;
  expectedPixelHeight: number;
}): Promise<CapturePixelScaleProof> {
  const { page, context } = options;
  await page.evaluate(
    ({ id, size, colors }) => {
      document.getElementById(id)?.remove();
      const probe = document.createElement('div');
      probe.id = id;
      probe.setAttribute('aria-hidden', 'true');
      Object.assign(probe.style, {
        position: 'fixed',
        left: '0',
        top: '0',
        width: `${size}px`,
        height: `${size}px`,
        zIndex: '2147483647',
        pointerEvents: 'none',
        background: `linear-gradient(to right, ${colors
          .map((color, index) => {
            const start = index * 25;
            const end = (index + 1) * 25;
            return `${color} ${start}%, ${color} ${end}%`;
          })
          .join(', ')})`,
        animation: 'none',
        transition: 'none',
        transform: 'none',
        opacity: '1',
      });
      document.documentElement.append(probe);
    },
    {
      id: PROBE_ID,
      size: CSS_SIZE,
      colors: COLORS.map(([red, green, blue]) => `rgb(${red}, ${green}, ${blue})`),
    },
  );
  await page.evaluate(
    () =>
      new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
      ),
  );

  const session = await context.newCDPSession(page);
  let frame: Buffer | undefined;
  let sessionId: number | undefined;
  try {
    await session.send('Page.enable');
    const rawMetrics = await session.send('Page.getLayoutMetrics');
    const layoutMetrics: CdpLayoutMetrics = {
      layoutViewport: {
        pageX: rawMetrics.layoutViewport.pageX,
        pageY: rawMetrics.layoutViewport.pageY,
        clientWidth: rawMetrics.layoutViewport.clientWidth,
        clientHeight: rawMetrics.layoutViewport.clientHeight,
      },
      ...(rawMetrics.cssLayoutViewport
        ? {
            cssLayoutViewport: {
              pageX: rawMetrics.cssLayoutViewport.pageX,
              pageY: rawMetrics.cssLayoutViewport.pageY,
              clientWidth: rawMetrics.cssLayoutViewport.clientWidth,
              clientHeight: rawMetrics.cssLayoutViewport.clientHeight,
            },
          }
        : {}),
    };
    const framePromise = new Promise<void>((resolve, reject) => {
      const listener = (payload: { data: string; sessionId: number }) => {
        try {
          frame = Buffer.from(payload.data, 'base64');
          sessionId = payload.sessionId;
          session.off('Page.screencastFrame', listener);
          resolve();
        } catch (error) {
          reject(error);
        }
      };
      session.on('Page.screencastFrame', listener);
    });
    await session.send('Page.startScreencast', {
      format: 'jpeg',
      quality: 90,
      everyNthFrame: 1,
      maxWidth: options.expectedPixelWidth,
      maxHeight: options.expectedPixelHeight,
    });
    await Promise.race([
      framePromise,
      setTimeout(5_000, undefined, { ref: false }).then(() => {
        throw new Error('Timed out waiting for the capture pixel-scale proof frame');
      }),
    ]);
    if (!frame || sessionId === undefined) throw new Error('Capture scale proof produced no frame');
    await session.send('Page.screencastFrameAck', { sessionId });
    await session.send('Page.stopScreencast');

    const image = await loadImage(frame);
    const sampleSize = CSS_SIZE * options.deviceScaleFactor;
    const canvas = createCanvas(sampleSize, sampleSize);
    const drawing = canvas.getContext('2d');
    drawing.drawImage(image, 0, 0, sampleSize, sampleSize, 0, 0, sampleSize, sampleSize);
    const bytes = canvas.data();
    const sampleY = Math.floor(sampleSize / 2);
    const samples = COLORS.map((expected, index) => {
      const x = Math.floor((index + 0.5) * (sampleSize / COLORS.length));
      const offset = (sampleY * sampleSize + x) * 4;
      const observed = [bytes[offset] ?? 0, bytes[offset + 1] ?? 0, bytes[offset + 2] ?? 0];
      const [expectedRed, expectedGreen, expectedBlue] = expected;
      const [observedRed = 0, observedGreen = 0, observedBlue = 0] = observed;
      const distance = Math.hypot(
        observedRed - expectedRed,
        observedGreen - expectedGreen,
        observedBlue - expectedBlue,
      );
      return { x, y: sampleY, expected: [...expected], observed, distance };
    });
    const passed =
      image.width === options.expectedPixelWidth &&
      image.height === options.expectedPixelHeight &&
      samples.every((sample) => sample.distance <= 60);
    const proof: CapturePixelScaleProof = {
      method: 'cdp-screencast-css-color-bands',
      passed,
      probeCssSize: { width: CSS_SIZE, height: CSS_SIZE },
      expectedPaintedScale: options.deviceScaleFactor,
      jpegDimensions: { width: image.width, height: image.height },
      samples,
      cdpLayoutMetrics: layoutMetrics,
    };
    assertCapturePixelScaleProof(proof);
    return proof;
  } finally {
    await session.send('Page.stopScreencast').catch(() => undefined);
    await session.detach().catch(() => undefined);
    await page
      .evaluate((id) => document.getElementById(id)?.remove(), PROBE_ID)
      .catch(() => undefined);
  }
}
