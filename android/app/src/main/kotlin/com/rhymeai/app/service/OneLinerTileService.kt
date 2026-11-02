package com.rhymeai.app.service

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.TileService
import com.rhymeai.app.ui.navigation.OneLinerAction
import com.rhymeai.app.widget.OneLinersWidget

/** Quick Settings "Record a line": opens the app already recording a one liner. */
class OneLinerTileService : TileService() {
    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        val intent = OneLinersWidget.intent(this, OneLinerAction.RECORD)
        val open = {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(
                    PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
        // The microphone needs the app in front, so a locked device unlocks first.
        if (isLocked) unlockAndRun(open) else open()
    }
}
