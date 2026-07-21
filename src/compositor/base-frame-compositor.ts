import { type Canvas, createCanvas, type Image, type SKRSContext2D } from '@napi-rs/canvas';
import { containRect } from './geometry.js';
import { rgbaBytes } from './rgba.js';
import {
  type CompositionFrameContext,
  OUTPUT_HEIGHT,
  OUTPUT_WIDTH,
  type RawRgbaFrame,
  type Rect,
  RGBA_BYTE_LENGTH,
  RGBA_STRIDE_BYTES,
} from './types.js';

export class BaseFrameCompositor {
  readonly contentRect: Rect;
  private readonly canvas: Canvas;
  private readonly context;

  constructor(
    readonly sourceWidth: number,
    readonly sourceHeight: number,
  ) {
    this.canvas = createCanvas(OUTPUT_WIDTH, OUTPUT_HEIGHT);
    this.context = this.canvas.getContext('2d');
    this.context.imageSmoothingEnabled = true;
    this.context.imageSmoothingQuality = 'high';
    this.contentRect = containRect(sourceWidth, sourceHeight, OUTPUT_WIDTH, OUTPUT_HEIGHT);
  }

  compose(frameContext: CompositionFrameContext, image: Image): RawRgbaFrame {
    return this.composeWithOverlay(frameContext, image);
  }

  composeWithOverlay(
    frameContext: CompositionFrameContext,
    image: Image,
    overlay?: (context: SKRSContext2D) => void,
  ): RawRgbaFrame {
    return this.composeSourceCropWithOverlay(
      frameContext,
      image,
      { x: 0, y: 0, width: this.sourceWidth, height: this.sourceHeight },
      overlay,
    );
  }

  composeSourceCropWithOverlay(
    frameContext: CompositionFrameContext,
    image: Image,
    sourceCrop: Rect,
    overlay?: (context: SKRSContext2D) => void,
  ): RawRgbaFrame {
    if (image.width !== this.sourceWidth || image.height !== this.sourceHeight) {
      throw new Error('Source image dimensions changed during composition');
    }
    this.context.globalCompositeOperation = 'copy';
    this.context.fillStyle = 'rgba(0, 0, 0, 1)';
    this.context.fillRect(0, 0, OUTPUT_WIDTH, OUTPUT_HEIGHT);
    this.context.globalCompositeOperation = 'source-over';
    const { x, y, width, height } = this.contentRect;
    this.context.drawImage(
      image,
      sourceCrop.x,
      sourceCrop.y,
      sourceCrop.width,
      sourceCrop.height,
      x,
      y,
      width,
      height,
    );
    overlay?.(this.context);
    const data = rgbaBytes(this.canvas.data());
    if (data.byteLength !== RGBA_BYTE_LENGTH)
      throw new Error('Canvas returned unexpected RGBA size');
    return {
      outputIndex: frameContext.outputIndex,
      outputTimestampMs: frameContext.outputTimestampMs,
      sourceIndex: frameContext.sourceIndex,
      sourceTimestampMs: frameContext.sourceTimestampMs,
      width: OUTPUT_WIDTH,
      height: OUTPUT_HEIGHT,
      strideBytes: RGBA_STRIDE_BYTES,
      byteLength: RGBA_BYTE_LENGTH,
      data,
    };
  }

  png(): Buffer {
    return this.canvas.toBuffer('image/png');
  }

  cropPng(rect: Rect): Buffer {
    const { x, y, width, height } = integerCrop(rect);
    const crop = createCanvas(width, height);
    crop.getContext('2d').drawImage(this.canvas, x, y, width, height, 0, 0, width, height);
    return crop.toBuffer('image/png');
  }

  sampleRgba(rect: Rect): Uint8Array {
    const { x, y, width, height } = integerCrop(rect);
    const sample = createCanvas(width, height);
    sample.getContext('2d').drawImage(this.canvas, x, y, width, height, 0, 0, width, height);
    return rgbaBytes(sample.data());
  }
}

function integerCrop(rect: Rect): Rect {
  if (
    !Number.isInteger(rect.x) ||
    !Number.isInteger(rect.y) ||
    !Number.isInteger(rect.width) ||
    !Number.isInteger(rect.height) ||
    rect.x < 0 ||
    rect.y < 0 ||
    rect.width < 1 ||
    rect.height < 1 ||
    rect.x + rect.width > OUTPUT_WIDTH ||
    rect.y + rect.height > OUTPUT_HEIGHT
  ) {
    throw new Error('Canvas crop must be an integer rectangle inside output bounds');
  }
  return rect;
}
