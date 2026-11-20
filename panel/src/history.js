// Formatting and shaping rules for the History tab.
//
// Kept out of `main.js` so the parts worth getting right - the clock, the
// percentage, and what a row falls back to when the device never resolved a
// title - are testable without a DOM (`panel/test/history.test.js`).

import { esc } from './validate.js';

// Milliseconds as `m:ss`, or `h:mm:ss` once there is an hour to show.
//
// A missing or nonsense duration answers `0:00` rather than `NaN`: the panel
// renders whatever a (possibly older) backend stored, and a row must not print
// arithmetic.
export function formatClock(ms) {
  const total = Math.max(0, Math.floor((Number(ms) || 0) / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (n) => String(n).padStart(2, '0');
  return hours > 0
    ? `${hours}:${pad(minutes)}:${pad(seconds)}`
    : `${minutes}:${pad(seconds)}`;
}

// Whole percent watched, clamped to 0..100. 0 when the duration is unknown,
// which is also what the app's own progress bar decides (nothing is drawn
// without a duration).
export function progressPercent(positionMs, durationMs) {
  const duration = Number(durationMs) || 0;
  const position = Number(positionMs) || 0;
  if (duration <= 0) return 0;
  return Math.min(100, Math.max(0, Math.round((position / duration) * 100)));
}

// Time left, e.g. `13:02 left`, or '' when there is no duration to count down
// from.
export function remainingLabel(positionMs, durationMs) {
  const duration = Number(durationMs) || 0;
  if (duration <= 0) return '';
  const left = Math.max(0, duration - (Number(positionMs) || 0));
  return left > 0 ? `${formatClock(left)} left` : '';
}

// Split into the two lists the tab renders, preserving the incoming order
// (the query orders by `updated_at` descending).
export function partitionHistory(rows) {
  const inProgress = [];
  const watched = [];
  for (const row of rows ?? []) {
    if (row?.watched) watched.push(row);
    else inProgress.push(row);
  }
  return { inProgress, watched };
}

// What to print as a row's name.
//
// The title is a *snapshot* the device sends with the state; a row written
// before that column existed, or one whose id the device could no longer
// resolve, still has to render as something. The provider id is stable and
// recognisable, so it is a better fallback than an empty line.
export function historyTitle(row) {
  const title = String(row?.title ?? '').trim();
  if (title) return title;
  const itemId = String(row?.item_id ?? '').trim();
  return itemId || 'Unknown title';
}

// Only http(s) URLs reach an `<img src>`.
//
// The server rejects anything else at write time, and the app clips to the same
// rules; this repeats the check because the panel renders whatever is in the
// row - including rows written by an older client or by hand.
export function safePoster(url) {
  const value = String(url ?? '').trim();
  return /^https?:\/\//i.test(value) ? value : '';
}

// `2026 · xtream`, skipping the parts that are unknown.
//
// The catalogue's `year` is whatever the provider sent, which is often a full
// release date (`2026-11-15`) rather than a year. Storage keeps it exactly -
// it is a snapshot, not a normalisation - and only the label is shortened.
export function historyMeta(row, sourceLabel) {
  const raw = String(row?.year ?? '').trim();
  const year = /^\d{4}/.test(raw) ? raw.slice(0, 4) : raw;
  const label = String(sourceLabel ?? '').trim();
  return [year, label].filter(Boolean).join(' · ');
}

// The thumbnail for a row: the wide artwork when the catalogue has one, the
// poster otherwise. History thumbs are drawn in landscape (16:9), and a 2:3
// poster cropped to that ratio loses most of the picture, so the backdrop is
// preferred whenever the device reported one.
export function artworkUrl(row) {
  return safePoster(row?.backdrop) || safePoster(row?.poster);
}

// One history row as HTML.
//
// Lives here rather than in `main.js` because every value in it comes from a
// provider (the device forwarded it), so this is the one place the panel's
// escaping has to hold for a *snapshot* field. Tested directly in
// `panel/test/history.test.js`.
//
// The progress bar is a native `<progress>` element, deliberately **not** a
// `<span style="width: N%">`. The panel's CSP is `style-src 'self'`, which
// strips inline style attributes in the built output (the dev server has no
// CSP, so this only shows up in production): a stripped width leaves the span
// at `width: auto`, i.e. **every bar renders full**. `<progress>` carries its
// value as an attribute and needs no inline style at all.
export function historyRowHtml(row, sourceLabel) {
  const art = artworkUrl(row);
  const title = historyTitle(row);
  const meta = historyMeta(row, sourceLabel);
  const left = remainingLabel(row?.position_ms, row?.duration_ms);
  const state = row?.watched
    ? '<div class="history-state">Watched</div>'
    : `<progress class="progress-bar" value="${progressPercent(row?.position_ms, row?.duration_ms)}" max="100" aria-label="${progressPercent(row?.position_ms, row?.duration_ms)}% watched"></progress>
       <div class="history-meta">${esc(formatClock(row?.position_ms))} / ${esc(formatClock(row?.duration_ms))}${left ? ` · ${esc(left)}` : ''}</div>`;
  const when = row?.updated_at ? new Date(row.updated_at).toLocaleDateString() : '';
  return `
    <div class="history-row">
      ${art ? `<img class="history-art" src="${esc(art)}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : '<div class="history-art"></div>'}
      <div class="history-main">
        <div class="history-title" title="${esc(title)}">${esc(title)}</div>
        ${meta ? `<div class="history-meta">${esc(meta)}</div>` : ''}
        ${state}
      </div>
      ${when ? `<div class="history-when">${esc(when)}</div>` : ''}
    </div>`;
}
