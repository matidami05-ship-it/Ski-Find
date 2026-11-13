package com.ski.find

import android.app.Application
import org.osmdroid.config.Configuration

class SkiFindApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Configuration.getInstance().apply {
            userAgentValue = "SkiFind/1.0 (com.ski.find)"
            osmdroidBasePath = cacheDir
            osmdroidTileCache = cacheDir.resolve("tiles")
        }
        LocationService.ensureChannel(this)
    }
}
