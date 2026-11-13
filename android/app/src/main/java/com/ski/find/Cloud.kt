package com.ski.find

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import java.time.Instant

/**
 * Talks to the Ski Grocery Firebase project (free Spark plan) over its REST API,
 * so the app needs no Firebase SDK or google-services.json.
 *
 * Data:
 *   findCodes/{CODE}                       { circleId }
 *   findCircles/{cid}                      { members: [uid], names: {uid: name}, joinCode }
 *   findCircles/{cid}/locations/{uid}      { name, lat, lng, accuracy, speed, battery, charging, platform, updated }
 */
object Config {
    const val API_KEY = "AIzaSyB3Uecm-SsyACyhDciZgkK_3Njxn9VjkFc"
    const val PROJECT_ID = "ski-grocery"
    // Sent in case the web API key is limited to the app's website.
    const val REFERER = "https://ski-grocery.web.app/"
}

class Prefs(ctx: Context) {
    private val p = ctx.applicationContext.getSharedPreferences("skifind", Context.MODE_PRIVATE)

    var uid: String?
        get() = p.getString("uid", null)
        set(v) = p.edit().putString("uid", v).apply()
    var idToken: String?
        get() = p.getString("idToken", null)
        set(v) = p.edit().putString("idToken", v).apply()
    var refreshToken: String?
        get() = p.getString("refreshToken", null)
        set(v) = p.edit().putString("refreshToken", v).apply()
    var tokenExpiry: Long
        get() = p.getLong("tokenExpiry", 0)
        set(v) = p.edit().putLong("tokenExpiry", v).apply()
    var circleId: String?
        get() = p.getString("circleId", null)
        set(v) = p.edit().putString("circleId", v).apply()
    var name: String
        get() = p.getString("name", "") ?: ""
        set(v) = p.edit().putString("name", v).apply()
    var sharing: Boolean
        get() = p.getBoolean("sharing", true)
        set(v) = p.edit().putBoolean("sharing", v).apply()
    var lastUploadAt: Long
        get() = p.getLong("lastUploadAt", 0)
        set(v) = p.edit().putLong("lastUploadAt", v).apply()
    var lastUploadLat: Double
        get() = Double.fromBits(p.getLong("lastUploadLat", 0))
        set(v) = p.edit().putLong("lastUploadLat", v.toBits()).apply()
    var lastUploadLng: Double
        get() = Double.fromBits(p.getLong("lastUploadLng", 0))
        set(v) = p.edit().putLong("lastUploadLng", v.toBits()).apply()
}

data class Person(
    val uid: String,
    val name: String,
    val lat: Double,
    val lng: Double,
    val accuracy: Double,
    val speed: Double,
    val battery: Int?,
    val charging: Boolean,
    val platform: String,
    val sharing: Boolean,
    val updated: Long,
)

data class Circle(
    val id: String,
    val members: List<String>,
    val names: Map<String, String>,
    val joinCode: String,
)

class HttpError(val code: Int, body: String) : Exception("HTTP $code ${body.take(300)}")

class Cloud(ctx: Context) {
    val prefs = Prefs(ctx)

    private val docRoot = "projects/${Config.PROJECT_ID}/databases/(default)/documents"
    private val base = "https://firestore.googleapis.com/v1/$docRoot"

    // ---------- HTTP ----------

    private fun http(method: String, url: String, body: JSONObject?, token: String?): JSONObject {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method
            c.connectTimeout = 15_000
            c.readTimeout = 20_000
            c.setRequestProperty("Content-Type", "application/json")
            c.setRequestProperty("Referer", Config.REFERER)
            if (token != null) c.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                c.doOutput = true
                c.outputStream.use { it.write(body.toString().toByteArray()) }
            }
            val code = c.responseCode
            val stream = if (code in 200..299) c.inputStream else c.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            if (code !in 200..299) throw HttpError(code, text)
            return if (text.isBlank()) JSONObject() else JSONObject(text)
        } finally {
            c.disconnect()
        }
    }

    // ---------- Sign-in (anonymous Firebase account, kept for good) ----------

    @Synchronized
    fun token(): String {
        val now = System.currentTimeMillis()
        prefs.idToken?.let { if (now < prefs.tokenExpiry - 120_000) return it }
        prefs.refreshToken?.let { rt ->
            try {
                val r = http(
                    "POST", "https://securetoken.googleapis.com/v1/token?key=${Config.API_KEY}",
                    JSONObject().put("grant_type", "refresh_token").put("refresh_token", rt), null
                )
                prefs.idToken = r.getString("id_token")
                prefs.refreshToken = r.getString("refresh_token")
                prefs.tokenExpiry = now + r.getString("expires_in").toLong() * 1000
                prefs.uid = r.getString("user_id")
                return r.getString("id_token")
            } catch (e: HttpError) {
                // 400 means the refresh token is gone; anything else (offline etc.) is retried later.
                if (e.code != 400) throw e
            }
        }
        val r = http(
            "POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${Config.API_KEY}",
            JSONObject().put("returnSecureToken", true), null
        )
        prefs.uid = r.getString("localId")
        prefs.idToken = r.getString("idToken")
        prefs.refreshToken = r.getString("refreshToken")
        prefs.tokenExpiry = now + r.getString("expiresIn").toLong() * 1000
        return r.getString("idToken")
    }

    fun uid(): String {
        token()
        return prefs.uid!!
    }

    // ---------- Firestore helpers ----------

    private fun getDoc(path: String): JSONObject? = try {
        http("GET", "$base/$path", null, token())
    } catch (e: HttpError) {
        if (e.code == 404) null else throw e
    }

    private fun commit(vararg writes: JSONObject) {
        http("POST", "$base:commit", JSONObject().put("writes", JSONArray(writes.toList())), token())
    }

    private fun name(path: String) = "$docRoot/$path"

    // ---------- Circle ----------

    fun loadCircle(cid: String): Circle? = try {
        getDoc("findCircles/$cid")?.let { parseCircle(cid, it) }
    } catch (e: HttpError) {
        if (e.code == 403) null else throw e // 403 = we're no longer in it
    }

    fun createCircle(myName: String): Circle {
        val uid = uid()
        val cid = randomId(20)
        var code = makeCode()
        repeat(3) { if (getDoc("findCodes/$code") != null) code = makeCode() }
        val circle = JSONObject()
            .put("name", name("findCircles/$cid"))
            .put("fields", JSONObject()
                .put("members", arr(str(uid)))
                .put("names", map(JSONObject().put(uid, str(myName))))
                .put("joinCode", str(code))
                .put("created", int(System.currentTimeMillis())))
        val codeDoc = JSONObject()
            .put("name", name("findCodes/$code"))
            .put("fields", JSONObject().put("circleId", str(cid)))
        commit(
            JSONObject().put("update", circle).put("currentDocument", JSONObject().put("exists", false)),
            JSONObject().put("update", codeDoc).put("currentDocument", JSONObject().put("exists", false)),
        )
        prefs.circleId = cid
        prefs.name = myName
        return Circle(cid, listOf(uid), mapOf(uid to myName), code)
    }

    /** Returns null if the code doesn't exist. */
    fun joinCircle(myName: String, rawCode: String): Circle? {
        val uid = uid()
        val code = rawCode.trim().uppercase()
        val codeDoc = getDoc("findCodes/$code") ?: return null
        val cid = fields(codeDoc).optJSONObject("circleId")?.optString("stringValue") ?: return null
        val already = loadCircle(cid) != null
        val write = JSONObject()
            .put("currentDocument", JSONObject().put("exists", true))
        if (already) {
            write.put("update", JSONObject()
                .put("name", name("findCircles/$cid"))
                .put("fields", JSONObject().put("names", map(JSONObject().put(uid, str(myName))))))
                .put("updateMask", JSONObject().put("fieldPaths", JSONArray().put("names.`$uid`")))
        } else {
            write.put("update", JSONObject()
                .put("name", name("findCircles/$cid"))
                .put("fields", JSONObject()
                    .put("names", map(JSONObject().put(uid, str(myName))))
                    .put("joinCodeUsed", str(code))))
                .put("updateMask", JSONObject().put("fieldPaths", JSONArray().put("names.`$uid`").put("joinCodeUsed")))
                .put("updateTransforms", JSONArray().put(JSONObject()
                    .put("fieldPath", "members")
                    .put("appendMissingElements", JSONObject().put("values", JSONArray().put(str(uid))))))
        }
        commit(write)
        prefs.circleId = cid
        prefs.name = myName
        return loadCircle(cid)
    }

    fun rename(cid: String, newName: String) {
        val uid = uid()
        commit(JSONObject()
            .put("update", JSONObject()
                .put("name", name("findCircles/$cid"))
                .put("fields", JSONObject().put("names", map(JSONObject().put(uid, str(newName))))))
            .put("updateMask", JSONObject().put("fieldPaths", JSONArray().put("names.`$uid`")))
            .put("currentDocument", JSONObject().put("exists", true)))
        prefs.name = newName
    }

    /** Removes someone (or yourself, when leaving) and their last location. */
    fun remove(cid: String, who: String) {
        commit(
            JSONObject().put("delete", name("findCircles/$cid/locations/$who")),
            JSONObject()
                .put("update", JSONObject().put("name", name("findCircles/$cid")).put("fields", JSONObject()))
                .put("updateMask", JSONObject().put("fieldPaths", JSONArray().put("names.`$who`")))
                .put("updateTransforms", JSONArray().put(JSONObject()
                    .put("fieldPath", "members")
                    .put("removeAllFromArray", JSONObject().put("values", JSONArray().put(str(who))))))
                .put("currentDocument", JSONObject().put("exists", true)),
        )
    }

    // ---------- Locations ----------

    fun uploadLocation(
        cid: String, lat: Double, lng: Double, accuracy: Double, speed: Double,
        battery: Int?, charging: Boolean, sharing: Boolean,
    ) {
        val uid = uid()
        val f = JSONObject()
            .put("name", str(prefs.name))
            .put("lat", dbl(lat))
            .put("lng", dbl(lng))
            .put("accuracy", dbl(accuracy))
            .put("speed", dbl(speed))
            .put("charging", bool(charging))
            .put("sharing", bool(sharing))
            .put("platform", str("android"))
        if (battery != null) f.put("battery", int(battery.toLong()))
        commit(JSONObject()
            .put("update", JSONObject().put("name", name("findCircles/$cid/locations/$uid")).put("fields", f))
            .put("updateTransforms", JSONArray().put(JSONObject()
                .put("fieldPath", "updated").put("setToServerValue", "REQUEST_TIME"))))
    }

    /** Marks this phone as paused without moving its pin. */
    fun setSharingFlag(cid: String, sharing: Boolean) {
        val uid = uid()
        commit(JSONObject()
            .put("update", JSONObject()
                .put("name", name("findCircles/$cid/locations/$uid"))
                .put("fields", JSONObject().put("sharing", bool(sharing))))
            .put("updateMask", JSONObject().put("fieldPaths", JSONArray().put("sharing")))
            .put("updateTransforms", JSONArray().put(JSONObject()
                .put("fieldPath", "updated").put("setToServerValue", "REQUEST_TIME"))))
    }

    fun locations(cid: String): List<Person> {
        val r = http("GET", "$base/findCircles/$cid/locations?pageSize=50", null, token())
        val docs = r.optJSONArray("documents") ?: return emptyList()
        return (0 until docs.length()).mapNotNull { i ->
            val d = docs.getJSONObject(i)
            val f = fields(d)
            val uid = d.getString("name").substringAfterLast('/')
            val lat = num(f, "lat") ?: return@mapNotNull null
            val lng = num(f, "lng") ?: return@mapNotNull null
            Person(
                uid = uid,
                name = f.optJSONObject("name")?.optString("stringValue") ?: "",
                lat = lat,
                lng = lng,
                accuracy = num(f, "accuracy") ?: 0.0,
                speed = num(f, "speed") ?: 0.0,
                battery = num(f, "battery")?.toInt(),
                charging = f.optJSONObject("charging")?.optBoolean("booleanValue") ?: false,
                platform = f.optJSONObject("platform")?.optString("stringValue") ?: "",
                sharing = f.optJSONObject("sharing")?.optBoolean("booleanValue", true) ?: true,
                updated = f.optJSONObject("updated")?.optString("timestampValue")
                    ?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() } ?: 0L,
            )
        }
    }

    // ---------- Value encoding ----------

    private fun parseCircle(cid: String, d: JSONObject): Circle {
        val f = fields(d)
        val members = f.optJSONObject("members")?.optJSONObject("arrayValue")?.optJSONArray("values")
        val names = f.optJSONObject("names")?.optJSONObject("mapValue")?.optJSONObject("fields")
        return Circle(
            id = cid,
            members = (0 until (members?.length() ?: 0)).map { members!!.getJSONObject(it).optString("stringValue") },
            names = names?.keys()?.asSequence()?.associateWith { names!!.getJSONObject(it).optString("stringValue") } ?: emptyMap(),
            joinCode = f.optJSONObject("joinCode")?.optString("stringValue") ?: "",
        )
    }

    private fun fields(d: JSONObject) = d.optJSONObject("fields") ?: JSONObject()

    private fun num(f: JSONObject, key: String): Double? {
        val v = f.optJSONObject(key) ?: return null
        if (v.has("doubleValue")) return v.optDouble("doubleValue")
        if (v.has("integerValue")) return v.optString("integerValue").toDoubleOrNull()
        return null
    }

    private fun str(s: String) = JSONObject().put("stringValue", s)
    private fun dbl(d: Double) = JSONObject().put("doubleValue", if (d.isFinite()) d else 0.0)
    private fun int(i: Long) = JSONObject().put("integerValue", i.toString())
    private fun bool(b: Boolean) = JSONObject().put("booleanValue", b)
    private fun arr(vararg v: JSONObject) = JSONObject().put("arrayValue", JSONObject().put("values", JSONArray(v.toList())))
    private fun map(fields: JSONObject) = JSONObject().put("mapValue", JSONObject().put("fields", fields))

    companion object {
        private val rnd = SecureRandom()
        private const val ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        private const val CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no 0/O or 1/I

        fun randomId(n: Int) = (1..n).map { ID_CHARS[rnd.nextInt(ID_CHARS.length)] }.joinToString("")
        fun makeCode() = (1..6).map { CODE_CHARS[rnd.nextInt(CODE_CHARS.length)] }.joinToString("")
    }
}
