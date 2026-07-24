import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { App } from '../../studio/ui/src/App.js';
import { PlanRail } from '../../studio/ui/src/components/PlanRail.js';
import type { Evidence, StepView } from '../../studio/ui/src/types.js';

// Replaces the pre-React studio/public/index.html structure test. Verifies the
// rebuilt React UI presents the same functional surfaces and the evidence/proof
// language, rendered as real components.

describe('Studio UI (React) parity surfaces', () => {
  it('renders authoring, preview, plan, and execution controls in the shell', () => {
    const html = renderToStaticMarkup(<App />);
    expect(html).toContain('Authoring');
    expect(html).toContain('AI chat');
    expect(html).toContain('Demo plan');
    expect(html).toContain('Inspect app');
    expect(html).toContain('Propose plan');
    expect(html).toContain('Validate edited plan');
    expect(html).toContain('Approve plan');
    expect(html).toContain('Start run');
    expect(html).toContain('Stop run');
    expect(html).toContain('No run yet');
    expect(html).toContain('Agent permission review');
  });

  it('renders completed steps with verified evidence and the approved plan hash', () => {
    const steps: StepView[] = [
      { index: 0, action: 'goto', target: 'http://127.0.0.1:4173/', state: 'completed' },
      {
        index: 1,
        action: 'click',
        target: 'testId="new-project"',
        state: 'completed',
        cursorVerified: true,
        pixelsVerified: true,
      },
    ];
    const evidence: Evidence = {
      captureScale: 'passed',
      cursorLanding: 'passed',
      targetPixels: 'passed',
      encoder: 'bounded backpressure (≤1 pending frame)',
      proofLevel: 'encoded-verified',
      proofHash: 'a'.repeat(64),
    };
    const html = renderToStaticMarkup(
      <PlanRail
        steps={steps}
        planHash={'b'.repeat(64)}
        approval="approved"
        evidence={evidence}
        proofHref="/api/artifacts/run-proof"
        videoReady
      />,
    );
    expect(html).toContain('approved');
    expect(html).toContain('sha256 bbbbbbbbbbbbbbbbbbbb…');
    expect(html).toContain('Click');
    expect(html).toContain('cursor ✓');
    expect(html).toContain('target px ✓');
    expect(html).toContain('encoded-verified');
    expect(html).toContain('Open proof manifest');
    expect(html).toContain('pbadge verified');
  });

  it('renders a failed step with the stable production error code in danger semantics', () => {
    const steps: StepView[] = [
      {
        index: 0,
        action: 'click',
        target: 'role=button "Missing"',
        state: 'failed',
        errorCode: 'TARGET_NOT_FOUND',
        errorMessage: 'No element matched the semantic target',
      },
    ];
    const html = renderToStaticMarkup(
      <PlanRail steps={steps} approval="approved" evidence={{}} videoReady={false} />,
    );
    expect(html).toContain('step failed');
    expect(html).toContain('TARGET_NOT_FOUND');
    expect(html).toContain('No element matched the semantic target');
  });
});
