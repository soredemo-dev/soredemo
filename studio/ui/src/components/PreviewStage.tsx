import { Glyph } from '../brand.js';

export function PreviewStage({
  previewSrc,
  videoSrc,
  captionText,
  live,
}: {
  previewSrc?: string;
  videoSrc?: string;
  captionText: string;
  live: boolean;
}): JSX.Element {
  return (
    <div className="stage">
      <div className="stage-body">
        {videoSrc ? (
          <div className="preview-frame">
            {/* biome-ignore lint/a11y/useMediaCaption: no audio track in demo output */}
            <video id="video" src={videoSrc} controls aria-label="Completed Soredemo video" />
          </div>
        ) : previewSrc ? (
          <div className="preview-frame">
            <img src={previewSrc} alt="Live capture preview frame" />
          </div>
        ) : (
          <div className="stage-empty">
            <Glyph className="glyph" />
            <div>
              <div style={{ color: 'var(--text-secondary)', fontWeight: 600 }}>No run yet</div>
              <div>Approve a plan and start a run to watch verified execution here.</div>
            </div>
          </div>
        )}
      </div>
      <div className="stage-caption">
        {live ? <span className="chip badge-live">● live sample</span> : null}
        <span>{captionText}</span>
      </div>
    </div>
  );
}
