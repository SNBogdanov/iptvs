import test from 'node:test';
import assert from 'node:assert/strict';

import {
  artworkUrl,
  formatClock,
  historyMeta,
  historyRowHtml,
  historyTitle,
  partitionHistory,
  progressPercent,
  remainingLabel,
  safePoster,
} from '../src/history.js';

// The History tab renders whatever the app reported. These are the rules that
// keep a row readable when the data is partial — which is normal: the title is
// a snapshot, the duration can be missing, and an older row has no metadata at
// all.

test('the clock reads as a player would show it', () => {
  assert.equal(formatClock(0), '0:00');
  assert.equal(formatClock(1000), '0:01');
  assert.equal(formatClock(59_000), '0:59');
  assert.equal(formatClock(60_000), '1:00');
  assert.equal(formatClock(3_600_000), '1:00:00');
  assert.equal(formatClock(4_021_000), '1:07:01');
});

test('missing or nonsense values never reach the screen as NaN', () => {
  assert.equal(formatClock(undefined), '0:00');
  assert.equal(formatClock(null), '0:00');
  assert.equal(formatClock('nonsense'), '0:00');
  assert.equal(formatClock(-5000), '0:00');
});

test('progress is a whole percent, clamped, and 0 without a duration', () => {
  assert.equal(progressPercent(400_649, 1_921_791), 21);
  assert.equal(progressPercent(0, 1000), 0);
  assert.equal(progressPercent(1000, 1000), 100);
  assert.equal(progressPercent(2000, 1000), 100, 'never past the bar');
  assert.equal(progressPercent(500, 0), 0);
  assert.equal(progressPercent(500, null), 0);
});

test('the countdown is the duration minus the position', () => {
  assert.equal(remainingLabel(60_000, 180_000), '2:00 left');
  assert.equal(remainingLabel(180_000, 180_000), '');
  assert.equal(remainingLabel(0, 0), '');
  assert.equal(remainingLabel(200_000, 180_000), '', 'past the end is not "−20 s left"');
});

test('rows split into in-progress and watched, keeping the order', () => {
  const rows = [
    { item_id: 'a', watched: false },
    { item_id: 'b', watched: true },
    { item_id: 'c', watched: false },
    { item_id: 'd', watched: true },
  ];
  const { inProgress, watched } = partitionHistory(rows);
  assert.deepEqual(
    inProgress.map((r) => r.item_id),
    ['a', 'c'],
  );
  assert.deepEqual(
    watched.map((r) => r.item_id),
    ['b', 'd'],
  );
  assert.deepEqual(partitionHistory(null), { inProgress: [], watched: [] });
});

test('a title falls back to the provider id, never to a blank line', () => {
  assert.equal(historyTitle({ title: '  A film  ', item_id: '1' }), 'A film');
  assert.equal(historyTitle({ title: '', item_id: '73776' }), '73776');
  assert.equal(historyTitle({ item_id: '' }), 'Unknown title');
  assert.equal(historyTitle(null), 'Unknown title');
});

test('only http(s) posters are rendered', () => {
  assert.equal(safePoster('https://cdn.example/p.jpg'), 'https://cdn.example/p.jpg');
  assert.equal(safePoster(' http://transmission/cover/1.jpg '), 'http://transmission/cover/1.jpg');
  assert.equal(safePoster('javascript:alert(1)'), '');
  assert.equal(safePoster('data:image/png;base64,AAAA'), '');
  assert.equal(safePoster('file:///c:/secret.png'), '');
  assert.equal(safePoster(null), '');
});

test('the meta line skips what is unknown', () => {
  assert.equal(historyMeta({ year: '2026' }, 'xtream'), '2026 · xtream');
  assert.equal(historyMeta({ year: '' }, 'xtream'), 'xtream');
  assert.equal(historyMeta({ year: '2026' }, ''), '2026');
  assert.equal(historyMeta({}, ''), '');
});

test('a provider release date is shown as its year', () => {
  // `media_items.year` holds whatever the provider sent — often a full date.
  assert.equal(historyMeta({ year: '2026-11-15' }, 'xtream'), '2026 · xtream');
  assert.equal(historyMeta({ year: '2026-11' }, ''), '2026');
  assert.equal(historyMeta({ year: 'MMXXVI' }, ''), 'MMXXVI');
});

test('a row renders the snapshot and its progress', () => {
  const html = historyRowHtml(
    {
      kind: 'movie',
      item_id: '73776',
      title: 'A film',
      year: '2026',
      poster: 'https://cdn.example/p.jpg',
      position_ms: 400_649,
      duration_ms: 1_921_791,
      watched: false,
      updated_at: '2026-11-20T09:21:37+00:00',
    },
    'xtream',
  );
  assert.match(html, /class="history-art" src="https:\/\/cdn\.example\/p\.jpg"/);
  assert.match(html, />A film</);
  assert.match(html, /2026 · xtream/);
  assert.match(html, /<progress class="progress-bar" value="21" max="100"/);
  assert.doesNotMatch(html, /style="/, 'CSP strips inline styles; a width must never ride in one');
  assert.match(html, /6:40 \/ 32:01/);
  assert.match(html, /25:21 left/);
  assert.doesNotMatch(html, /Watched/);
});

test('the landscape thumb prefers the backdrop and falls back to the poster', () => {
  assert.equal(
    artworkUrl({
      backdrop: 'https://cdn.example/wide.jpg',
      poster: 'https://cdn.example/tall.jpg',
    }),
    'https://cdn.example/wide.jpg',
  );
  assert.equal(
    artworkUrl({ backdrop: '', poster: 'https://cdn.example/tall.jpg' }),
    'https://cdn.example/tall.jpg',
  );
  assert.equal(
    artworkUrl({
      backdrop: 'javascript:alert(1)',
      poster: 'https://cdn.example/tall.jpg',
    }),
    'https://cdn.example/tall.jpg',
    'an unusable backdrop must not hide a usable poster',
  );
  assert.equal(artworkUrl({}), '');
  assert.equal(artworkUrl(null), '');
});

test('a watched row says so and draws no bar', () => {
  const html = historyRowHtml(
    {
      item_id: '1',
      title: 'Done',
      watched: true,
      position_ms: 0,
      duration_ms: 0,
      updated_at: '2026-11-20T09:18:41+00:00',
    },
    '',
  );
  assert.match(html, /history-state">Watched</);
  assert.doesNotMatch(html, /progress-bar/);
});

test('provider text cannot break out of the markup', () => {
  const html = historyRowHtml(
    {
      item_id: '1"><script>alert(1)</script>',
      title: '<img src=x onerror=alert(1)>',
      year: '"><b>',
      poster: 'https://cdn.example/" onerror="alert(1)',
    },
    '<script>',
  );
  assert.doesNotMatch(html, /<script>|<b>|<img src=x/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /&quot; onerror=&quot;alert\(1\)/);
});

test('a row without metadata still renders its id', () => {
  const html = historyRowHtml({ item_id: '73776', watched: true }, '');
  assert.match(html, />73776</);
});

