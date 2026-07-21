import { z } from 'zod';

const NonEmptyStringSchema = z
  .string()
  .min(1)
  .regex(/\S/, 'Must contain a non-whitespace character');
const DurationSchema = z.number().int().positive();
const CoordinateSchema = z.number().finite().nonnegative();
const HttpUrlSchema = z.url({ protocol: /^https?$/ });

const RoleTargetSchema = z.strictObject({
  role: NonEmptyStringSchema,
  name: NonEmptyStringSchema.optional(),
});

const LabelTargetSchema = z.strictObject({
  label: NonEmptyStringSchema,
});

const TestIdTargetSchema = z.strictObject({
  testId: NonEmptyStringSchema,
});

const TextTargetSchema = z.strictObject({
  text: NonEmptyStringSchema,
  exact: z.boolean().optional(),
});

const CssTargetSchema = z.strictObject({
  css: NonEmptyStringSchema,
});

export const TargetInputSchema = z
  .union([
    RoleTargetSchema,
    LabelTargetSchema,
    TestIdTargetSchema,
    TextTargetSchema,
    CssTargetSchema,
  ])
  .meta({ title: 'Semantic target' });

export const IntentInputSchema = z.strictObject({
  goal: NonEmptyStringSchema,
  audience: NonEmptyStringSchema.optional(),
  success: NonEmptyStringSchema.optional(),
  targetDurationMs: DurationSchema.optional(),
});

export const ViewportInputSchema = z.strictObject({
  width: z.number().int().positive(),
  height: z.number().int().positive(),
});

export const StyleInputSchema = z.strictObject({
  preset: z.literal('studio').optional(),
  pace: z.enum(['fast', 'balanced', 'calm']).optional(),
  seed: z.number().int().safe().optional(),
});

export const GotoActionInputSchema = z.strictObject({
  action: z.literal('goto'),
  url: HttpUrlSchema,
});

export const DurationWaitActionInputSchema = z.strictObject({
  action: z.literal('wait'),
  durationMs: DurationSchema,
});

export const ConditionWaitActionInputSchema = z.strictObject({
  action: z.literal('wait'),
  until: z.strictObject({
    visible: TargetInputSchema,
  }),
  timeoutMs: DurationSchema.optional(),
  settleMs: z.number().int().nonnegative().optional(),
});

export const WaitActionInputSchema = z.union([
  DurationWaitActionInputSchema,
  ConditionWaitActionInputSchema,
]);

export const MoveToActionInputSchema = z.strictObject({
  action: z.literal('moveTo'),
  target: TargetInputSchema,
});

export const ClickActionInputSchema = z.strictObject({
  action: z.literal('click'),
  target: TargetInputSchema,
  emphasis: z.enum(['primary', 'secondary']).optional(),
  focusAfter: z
    .strictObject({
      target: TargetInputSchema,
    })
    .optional(),
});

export const TypeActionInputSchema = z.strictObject({
  action: z.literal('type'),
  target: TargetInputSchema,
  text: z.string(),
});

export const TargetScrollToActionInputSchema = z.strictObject({
  action: z.literal('scrollTo'),
  target: TargetInputSchema,
  durationMs: DurationSchema,
});

export const CoordinateScrollToActionInputSchema = z.strictObject({
  action: z.literal('scrollTo'),
  x: CoordinateSchema.optional(),
  y: CoordinateSchema,
  durationMs: DurationSchema,
});

export const ScrollToActionInputSchema = z.union([
  TargetScrollToActionInputSchema,
  CoordinateScrollToActionInputSchema,
]);

export const ActionInputSchema = z.union([
  GotoActionInputSchema,
  DurationWaitActionInputSchema,
  ConditionWaitActionInputSchema,
  MoveToActionInputSchema,
  ClickActionInputSchema,
  TypeActionInputSchema,
  TargetScrollToActionInputSchema,
  CoordinateScrollToActionInputSchema,
]);

export const ScriptInputSchema = z
  .strictObject({
    version: z.literal(1),
    name: NonEmptyStringSchema,
    url: HttpUrlSchema,
    intent: IntentInputSchema,
    viewport: ViewportInputSchema.optional(),
    style: StyleInputSchema.optional(),
    actions: z.array(ActionInputSchema).min(1),
  })
  .meta({
    title: 'Soredemo Demo Plan',
    description: 'A declarative plan for demonstrating a real web application.',
  });

export type ScriptInput = z.input<typeof ScriptInputSchema>;
export type TargetInput = z.input<typeof TargetInputSchema>;
