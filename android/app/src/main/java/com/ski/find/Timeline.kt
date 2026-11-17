package com.ski.find

import android.location.Location

/** A day's history turned into "stayed here" and "moving" pieces, like Life360's timeline. */
sealed class Segment {
    abstract val start: Long
    abstract val end: Long

    data class Stay(
        val lat: Double, val lng: Double,
        override val start: Long, override val end: Long,
        val ongoing: Boolean,
    ) : Segment()

    data class Move(
        override val start: Long, override val end: Long,
        val meters: Double, val ongoing: Boolean,
    ) : Segment()
}

object Timeline {
    private const val STAY_RADIUS = 150f            // m
    private const val MIN_STAY = 8 * 60_000L        // shorter stops count as part of a trip
    private const val GAP = 10 * 60_000L

    private fun dist(aLat: Double, aLng: Double, bLat: Double, bLng: Double): Float {
        val out = FloatArray(1)
        Location.distanceBetween(aLat, aLng, bLat, bLng, out)
        return out[0]
    }

    /**
     * [points] oldest first. [now] is used to keep the last stay "ongoing" on today's timeline;
     * [dayEnd] closes the last stay on earlier days. Returns oldest first.
     */
    fun build(points: List<HistPoint>, isToday: Boolean, now: Long, dayEnd: Long): List<Segment> {
        val p = points.filter { it.accuracy < 300 }
        val n = p.size
        if (n == 0) return emptyList()

        class S(val from: Int, val to: Int, val lat: Double, val lng: Double, val start: Long, val end: Long, val ongoing: Boolean)
        val stays = mutableListOf<S>()
        var i = 0
        while (i < n) {
            var lat = p[i].lat
            var lng = p[i].lng
            var j = i + 1
            while (j < n && dist(lat, lng, p[j].lat, p[j].lng) <= STAY_RADIUS) {
                val k = (j - i + 1).toDouble()
                lat += (p[j].lat - lat) / k
                lng += (p[j].lng - lng) / k
                j++
            }
            val start = p[i].t
            val lastIn = p[j - 1].t
            val atEnd = j == n
            // iOS only reports when you move again, so a long gap before the next point means you left around then.
            val end = when {
                !atEnd -> if (p[j].t - lastIn > GAP) p[j].t - 2 * 60_000L else lastIn
                isToday -> now
                else -> maxOf(lastIn, dayEnd)
            }
            if (end - start >= MIN_STAY) {
                stays += S(i, j - 1, lat, lng, start, end, atEnd && isToday)
                i = j
            } else {
                i++
            }
        }

        fun pathMeters(from: Int, to: Int): Double {
            var m = 0.0
            for (k in from until to) m += dist(p[k].lat, p[k].lng, p[k + 1].lat, p[k + 1].lng)
            return m
        }

        val out = mutableListOf<Segment>()
        var prevIdx = 0
        var prevEnd = p[0].t
        for ((idx, s) in stays.withIndex()) {
            val from = if (idx == 0) 0 else prevIdx
            if (s.from > from || (idx > 0 && s.start - prevEnd > 60_000L)) {
                val meters = pathMeters(from, s.from)
                if (meters > 100) out += Segment.Move(prevEnd, s.start, meters, false)
            }
            out += Segment.Stay(s.lat, s.lng, s.start, s.end, s.ongoing)
            prevIdx = s.to
            prevEnd = s.end
        }
        if (prevIdx < n - 1) {
            val meters = pathMeters(prevIdx, n - 1)
            if (meters > 100) out += Segment.Move(prevEnd, if (isToday) maxOf(p[n - 1].t, prevEnd) else p[n - 1].t, meters, isToday)
        }
        return out
    }
}
