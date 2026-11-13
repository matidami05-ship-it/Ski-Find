package com.ski.find

import android.app.Application
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

    init {
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
