package com.ski.find

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Checks this repo's GitHub Releases for a newer APK (tags look like "android-12"),
 * downloads it and hands it to Android's installer. Every build is signed with the same
 * key, so it installs over the current app and keeps the pairing and settings.
 */
object Updater {
    private const val LATEST = "https://api.github.com/repos/matidami05-ship-it/Ski-Find/releases/latest"

    data class Update(val build: Int, val apkUrl: String, val notes: String)

    fun currentBuild(ctx: Context): Int =
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).longVersionCode.toInt()

    /** Newer build on GitHub, or null if this one is the newest. Throws when offline. */
    fun check(ctx: Context): Update? {
        val c = URL(LATEST).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15_000
            c.readTimeout = 20_000
            c.setRequestProperty("Accept", "application/vnd.github+json")
            c.setRequestProperty("User-Agent", "SkiFind")
            if (c.responseCode != 200) throw HttpError(c.responseCode, "")
            val r = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
            val build = r.optString("tag_name").substringAfterLast('-').toIntOrNull() ?: return null
            if (build <= currentBuild(ctx)) return null
            val assets = r.optJSONArray("assets") ?: return null
            val apk = (0 until assets.length()).map { assets.getJSONObject(it) }
                .firstOrNull { it.optString("name").endsWith(".apk") } ?: return null
            return Update(build, apk.getString("browser_download_url"), r.optString("name"))
        } finally {
            c.disconnect()
        }
    }

    /** Downloads the APK into the app's cache. [progress] gets 0..1. */
    fun download(ctx: Context, update: Update, progress: (Float) -> Unit): File {
        val dir = File(ctx.cacheDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val out = File(dir, "SkiFind-${update.build}.apk")
        var url = URL(update.apkUrl)
        var c: HttpURLConnection
        var hops = 0
        while (true) {
            c = url.openConnection() as HttpURLConnection
            c.connectTimeout = 15_000
            c.readTimeout = 30_000
            c.instanceFollowRedirects = false
            c.setRequestProperty("User-Agent", "SkiFind")
            val code = c.responseCode
            if (code in 300..399 && hops++ < 5) {
                url = URL(url, c.getHeaderField("Location"))
                c.disconnect()
                continue
            }
            if (code != 200) throw HttpError(code, "")
            break
        }
        try {
            val total = c.contentLengthLong.takeIf { it > 0 }
            c.inputStream.use { input ->
                out.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    var done = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        done += n
                        if (total != null) progress(done.toFloat() / total)
                    }
                }
            }
        } finally {
            c.disconnect()
        }
        return out
    }

    /** True once the user has let Ski Find install apps (asked the first time only). */
    fun canInstall(ctx: Context) = ctx.packageManager.canRequestPackageInstalls()

    fun openInstallPermission(ctx: Context) {
        ctx.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    fun install(ctx: Context, apk: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", apk)
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
