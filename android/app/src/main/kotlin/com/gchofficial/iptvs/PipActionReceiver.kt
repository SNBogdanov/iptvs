package com.gchofficial.iptvs

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Delivers the picture-in-picture menu actions to the live player.
 *
 * A broadcast rather than an activity intent: the PendingIntents configured in
 * `HdrPlayerActivity.pipParams()` must not bring the app to the foreground,
 * which is what `getActivity` would do. The receiver is not exported and only
 * ever called from those PendingIntents.
 */
class PipActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != HdrPlayerActivity.ACTION_PIP) return
        HdrPlayerActivity.handlePipAction(
            intent.getStringExtra(HdrPlayerActivity.EXTRA_PIP_COMMAND),
        )
    }
}
