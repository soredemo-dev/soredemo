import type { RunPhase } from '../types.js';

export function StatusBar({
  phase,
  lastEvent,
  projectRoot,
  version,
}: {
  phase: RunPhase;
  lastEvent: string;
  projectRoot: string;
  version: string;
}): JSX.Element {
  return (
    <div className="statusbar">
      <span className={`run-state ${phase}`}>
        <span className="dot" />
        {phase}
      </span>
      <span className="sep">|</span>
      <span className="ticker mono">{lastEvent || 'no events yet'}</span>
      <span className="sep">|</span>
      <span title={projectRoot}>{projectRoot}</span>
      <span className="sep">|</span>
      <span className="mono">v{version}</span>
    </div>
  );
}
