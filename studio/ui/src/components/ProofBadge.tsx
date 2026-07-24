type Tone = 'verified' | 'danger' | 'info' | 'neutral';

export function ProofBadge({
  tone = 'neutral',
  label,
  value,
}: {
  tone?: Tone;
  label: string;
  value?: string;
}): JSX.Element {
  const cls = tone === 'neutral' ? 'pbadge' : `pbadge ${tone}`;
  return (
    <span className={cls}>
      {label}
      {value ? <span className="mono">{value}</span> : null}
    </span>
  );
}
