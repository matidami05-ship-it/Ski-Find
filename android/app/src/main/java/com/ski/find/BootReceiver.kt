package com.ski.find

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Turns sharing back on after the phone restarts or the app updates. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            // Starting from the background needs "Allow all the time".
            if (LocationService.hasBackground(context)) LocationService.start(context)
        }
    }
}
