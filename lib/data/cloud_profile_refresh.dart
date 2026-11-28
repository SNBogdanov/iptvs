/// A one-shot request for the home screen to refresh the cloud profile the
/// picker just switched to.
///
/// The switch itself is **local** — capture the outgoing profile's snapshot,
/// write the new profile id, restore that profile's own snapshot — and it hands
/// the screen over as soon as those writes land. The **network** half (telling
/// the server about the new profile, then pulling sources, metadata, favourites
/// and watch state) is four round trips and used to run *before* the handover:
/// the picker spun while the sources had already been replaced and the profile
/// identity had not changed yet, which on a slow link took minutes.
///
/// This flag is how the picker tells `HomeShell` to do that half afterwards.
/// Process-wide and consumed once — a switch is an event, not a state, so a
/// plain bool is enough and a lost flag only costs a missed refresh.
library;

bool _pending = false;

/// Marks the cloud profile as needing a refresh after the handover.
void requestCloudProfileRefresh() {
  _pending = true;
}

/// Consumes the request, if any. Called from `HomeShell._loadActive`.
bool takeCloudProfileRefresh() {
  if (!_pending) return false;
  _pending = false;
  return true;
}
