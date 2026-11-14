package com.ski.find

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.net.Uri
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import android.location.Address
import android.location.Geocoder
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.coroutines.resume

data class UiState(
    val ready: Boolean = false,
    val circle: Circle? = null,
    val people: List<Person> = emptyList(),
    val myUid: String? = null,
    val myName: String = "",
    val sharing: Boolean = true,
    val busy: Boolean = false,
    val error: String? = null,
    val offline: Boolean = false,
    val addresses: Map<String, String> = emptyMap(),
    /** uid -> profile photo */
    val photos: Map<String, Bitmap> = emptyMap(),
    /** Newer version on GitHub, if any. */
    val update: Updater.Update? = null,
    /** "Checking…", "Downloading 40%", "You're on the newest version", or an error. */
    val updateStatus: String? = null,
    val updateBusy: Boolean = false,
)

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val cloud = Cloud(app)
    private val prefs = cloud.prefs
    private val _state = MutableStateFlow(
        UiState(myUid = prefs.uid, myName = prefs.name, sharing = prefs.sharing)
    )
    val state: StateFlow<UiState> = _state

    private var pollJob: Job? = null
    private val geoCache = java.util.concurrent.ConcurrentHashMap<String, String>()

    private val photoDir = File(app.filesDir, "photos").apply { mkdirs() }
    private val photoPrefs = app.getSharedPreferences("photoVersions", android.content.Context.MODE_PRIVATE)

    init {
        // Show saved photos straight away.
        val saved = photoPrefs.all.keys.mapNotNull { uid ->
            BitmapFactory.decodeFile(File(photoDir, "$uid.jpg").path)?.let { uid to it }
        }.toMap()
        _state.update { it.copy(photos = saved) }
        checkForUpdate(quiet = true)
        val cid = prefs.circleId
        if (cid == null) {
            _state.update { it.copy(ready = true) }
        } else {
            // Show the map straight away; the circle details fill in when loaded.
            _state.update { it.copy(ready = true, circle = Circle(cid, emptyList(), emptyMap(), "")) }
        }
    }

    /** Called while the app is on screen. */
    fun startPolling() {
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            var tick = 0
            while (isActive) {
                val cid = prefs.circleId
                if (cid != null) {
                    try {
                        if (tick % 6 == 0) {
                            val c = withContext(Dispatchers.IO) { cloud.loadCircle(cid) }
                            if (c == null) {
                                // We were removed on the other phone.
                                prefs.circleId = null
                                LocationService.stop(getApplication())
                                _state.update { it.copy(circle = null, people = emptyList()) }
                            } else {
                                _state.update { it.copy(circle = c, myUid = prefs.uid) }
                                withContext(Dispatchers.IO) { syncPhotos(c) }
                            }
                        }
                        if (prefs.circleId != null) {
                            val people = withContext(Dispatchers.IO) { cloud.locations(cid) }
                            val members = _state.value.circle?.members.orEmpty()
                            val visible = if (members.isEmpty()) people else people.filter { it.uid in members }
                            _state.update { it.copy(people = visible, offline = false) }
                            lookupAddresses(visible)
                        }
                    } catch (e: Exception) {
                        _state.update { it.copy(offline = true) }
                    }
                }
                tick++
                delay(10_000)
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    fun refreshNow() {
        stopPolling()
        startPolling()
    }

    fun create(name: String) = act {
        val c = cloud.createCircle(name.trim())
        prefs.sharing = true
        _state.update { it.copy(circle = c, myUid = prefs.uid, myName = prefs.name, sharing = true) }
    }

    fun join(name: String, code: String) = act {
        val c = cloud.joinCircle(name.trim(), code)
            ?: throw UserError("That code wasn't found. Check it on the other phone.")
        prefs.sharing = true
        _state.update { it.copy(circle = c, myUid = prefs.uid, myName = prefs.name, sharing = true) }
    }

    /** Join someone else's code from Settings, leaving the group this phone is in now. */
    fun switchTo(code: String) = act {
        val old = prefs.circleId
        val name = prefs.name.ifBlank { "Me" }
        val c = cloud.joinCircle(name, code)
            ?: throw UserError("That code wasn't found. Check it on the other phone.")
        if (old != null && old != c.id) runCatching { cloud.remove(old, cloud.uid()) }
        prefs.sharing = true
        prefs.lastUploadAt = 0
        _state.update { it.copy(circle = c, people = emptyList(), myUid = prefs.uid, myName = prefs.name, sharing = true) }
        LocationService.start(getApplication())
        refreshNow()
    }

    fun rename(name: String) = act {
        val cid = prefs.circleId ?: return@act
        cloud.rename(cid, name.trim())
        _state.update { it.copy(myName = prefs.name) }
        prefs.lastUploadAt = 0 // send the new name with the next position
        LocationService.start(getApplication())
    }

    fun setSharing(on: Boolean) {
        prefs.sharing = on
        _state.update { it.copy(sharing = on) }
        val cid = prefs.circleId ?: return
        if (on) {
            LocationService.start(getApplication())
        } else {
            LocationService.stop(getApplication())
            viewModelScope.launch(Dispatchers.IO) { runCatching { cloud.setSharingFlag(cid, false) } }
        }
    }

    fun removeMember(uid: String) = act {
        val cid = prefs.circleId ?: return@act
        cloud.remove(cid, uid)
        _state.update { s -> s.copy(people = s.people.filter { it.uid != uid }) }
        refreshNow()
    }

    fun leave() = act {
        val cid = prefs.circleId ?: return@act
        LocationService.stop(getApplication())
        runCatching { cloud.remove(cid, cloud.uid()) }
        prefs.circleId = null
        prefs.lastUploadAt = 0
        _state.update { it.copy(circle = null, people = emptyList()) }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    private class UserError(msg: String) : Exception(msg)

    private fun act(block: suspend () -> Unit) {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null) }
            try {
                withContext(Dispatchers.IO) { block() }
            } catch (e: UserError) {
                _state.update { it.copy(error = e.message) }
            } catch (e: HttpError) {
                _state.update { it.copy(error = "Something went wrong (${e.code}). Try again.") }
            } catch (e: Exception) {
                _state.update { it.copy(error = "Couldn't reach Ski Find. Check your connection and try again.") }
            } finally {
                _state.update { it.copy(busy = false) }
            }
        }
    }

    // ---------- App updates ----------

    val currentBuild: Int get() = Updater.currentBuild(getApplication())

    fun checkForUpdate(quiet: Boolean = false) {
        if (_state.value.updateBusy) return
        viewModelScope.launch {
            _state.update { it.copy(updateBusy = true, updateStatus = if (quiet) it.updateStatus else "Checking…") }
            try {
                val u = withContext(Dispatchers.IO) { Updater.check(getApplication()) }
                _state.update {
                    it.copy(
                        update = u,
                        updateStatus = when {
                            u != null -> "Build ${u.build} is ready to install."
                            quiet -> null
                            else -> "You're on the newest version."
                        }
                    )
                }
            } catch (e: Exception) {
                if (!quiet) _state.update { it.copy(updateStatus = "Couldn't check for updates. Check your connection.") }
            } finally {
                _state.update { it.copy(updateBusy = false) }
            }
        }
    }

    /** Downloads the update and opens Android's installer. */
    fun installUpdate(activity: android.content.Context) {
        val u = _state.value.update ?: return
        if (_state.value.updateBusy) return
        if (!Updater.canInstall(activity)) {
            _state.update { it.copy(updateStatus = "Turn on \"Allow from this source\" for Ski Find, then come back and tap Install again.") }
            Updater.openInstallPermission(activity)
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(updateBusy = true, updateStatus = "Downloading…") }
            try {
                val apk = withContext(Dispatchers.IO) {
                    Updater.download(getApplication(), u) { f ->
                        _state.update { it.copy(updateStatus = "Downloading ${(f * 100).toInt()}%") }
                    }
                }
                _state.update { it.copy(updateStatus = "Tap Update on the next screen.") }
                Updater.install(activity, apk)
            } catch (e: Exception) {
                _state.update { it.copy(updateStatus = "Download failed. Try again.") }
            } finally {
                _state.update { it.copy(updateBusy = false) }
            }
        }
    }

    // ---------- Profile photos ----------

    /** Downloads photos that are new or changed since last time; drops ones that were removed. */
    private fun syncPhotos(c: Circle) {
        for (uid in c.members) {
            val version = c.photos[uid]
            if (!version.isNullOrEmpty()) {
                if (photoPrefs.getString(uid, null) == version) continue
                val b64 = runCatching { cloud.loadPhoto(c.id, uid) }.getOrNull() ?: continue
                val bytes = runCatching { Base64.decode(b64, Base64.DEFAULT) }.getOrNull() ?: continue
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: continue
                savePhoto(uid, bytes, version)
                _state.update { it.copy(photos = it.photos + (uid to bmp)) }
            } else if (_state.value.photos.containsKey(uid)) {
                deletePhoto(uid)
                _state.update { it.copy(photos = it.photos - uid) }
            }
        }
    }

    private fun savePhoto(uid: String, bytes: ByteArray, version: String) {
        File(photoDir, "$uid.jpg").writeBytes(bytes)
        photoPrefs.edit().putString(uid, version).apply()
    }

    private fun deletePhoto(uid: String) {
        File(photoDir, "$uid.jpg").delete()
        photoPrefs.edit().remove(uid).apply()
    }

    fun setMyPhoto(uri: Uri) = act {
        val cid = prefs.circleId ?: return@act
        val bytes = squareJpeg(uri) ?: throw UserError("Couldn't open that picture. Try another one.")
        val version = cloud.setPhoto(cid, Base64.encodeToString(bytes, Base64.NO_WRAP))
        val me = cloud.uid()
        savePhoto(me, bytes, version)
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { bmp ->
            _state.update { it.copy(photos = it.photos + (me to bmp)) }
        }
    }

    fun removeMyPhoto() = act {
        val cid = prefs.circleId ?: return@act
        cloud.removePhoto(cid)
        val me = cloud.uid()
        deletePhoto(me)
        _state.update { it.copy(photos = it.photos - me) }
    }

    /** Center-cropped 256×256 JPEG, roughly 15–30 KB. */
    private fun squareJpeg(uri: Uri, size: Int = 256): ByteArray? = try {
        val src = ImageDecoder.decodeBitmap(ImageDecoder.createSource(getApplication<Application>().contentResolver, uri)) { d, info, _ ->
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val s = info.size
            val shortSide = minOf(s.width, s.height)
            if (shortSide > size * 2) {
                val k = shortSide / (size * 2)
                d.setTargetSize(s.width / k, s.height / k)
            }
        }
        val side = minOf(src.width, src.height)
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val f = size.toFloat() / side
        Canvas(out).apply {
            translate((size - src.width * f) / 2f, (size - src.height * f) / 2f)
            scale(f, f)
            drawBitmap(src, 0f, 0f, android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG))
        }
        ByteArrayOutputStream().use { bos ->
            out.compress(Bitmap.CompressFormat.JPEG, 80, bos)
            bos.toByteArray()
        }
    } catch (e: Exception) {
        null
    }

    // ---------- Street addresses ----------

    private fun lookupAddresses(people: List<Person>) {
        viewModelScope.launch(Dispatchers.IO) {
            for (p in people) {
                // ~50 m grid so we don't look up the same spot every 10 seconds.
                val key = String.format(Locale.US, "%.4f,%.4f", p.lat, p.lng)
                val text = geoCache[key] ?: reverseGeocode(p.lat, p.lng)?.also { geoCache[key] = it } ?: continue
                if (_state.value.addresses[p.uid] != text) {
                    _state.update { it.copy(addresses = it.addresses + (p.uid to text)) }
                }
            }
        }
    }

    private suspend fun reverseGeocode(lat: Double, lng: Double): String? {
        if (!Geocoder.isPresent()) return null
        val geocoder = Geocoder(getApplication(), Locale.getDefault())
        val addr: Address? = try {
            if (Build.VERSION.SDK_INT >= 33) {
                suspendCancellableCoroutine { cont ->
                    geocoder.getFromLocation(lat, lng, 1, object : Geocoder.GeocodeListener {
                        override fun onGeocode(addresses: MutableList<Address>) {
                            if (cont.isActive) cont.resume(addresses.firstOrNull())
                        }
                        override fun onError(errorMessage: String?) {
                            if (cont.isActive) cont.resume(null)
                        }
                    })
                }
            } else {
                @Suppress("DEPRECATION")
                geocoder.getFromLocation(lat, lng, 1)?.firstOrNull()
            }
        } catch (e: Exception) {
            null
        }
        addr ?: return null
        val street = listOfNotNull(addr.subThoroughfare, addr.thoroughfare).joinToString(" ").trim()
        val town = addr.locality ?: addr.subAdminArea ?: ""
        val parts = listOf(street, town).filter { it.isNotBlank() }
        return if (parts.isNotEmpty()) parts.joinToString(", ")
        else addr.getAddressLine(0)?.split(",")?.take(2)?.joinToString(",")?.trim()
    }
}
