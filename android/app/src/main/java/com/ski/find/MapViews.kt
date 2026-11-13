package com.ski.find

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polygon

/** Where the map should move to. A new object each time, so the same target can be requested twice. */
class Focus(val uid: String?) // null = show everyone

private val PALETTE = intArrayOf(
    0xFF2F80ED.toInt(), // blue (you)
    0xFFE0559A.toInt(), // pink
    0xFF27AE60.toInt(), // green
    0xFFF2994A.toInt(), // orange
    0xFF9B51E0.toInt(), // purple
    0xFF00A8A8.toInt(), // teal
)

fun personColor(uid: String, myUid: String?, members: List<String>): Int {
    if (uid == myUid) return PALETTE[0]
    val others = members.filter { it != myUid }
    val i = others.indexOf(uid).let { if (it < 0) (uid.hashCode() and 0xFFFF) else it }
    return PALETTE[1 + i % (PALETTE.size - 1)]
}

private fun avatar(ctx: Context, name: String, color: Int, dim: Boolean): BitmapDrawable {
    val d = ctx.resources.displayMetrics.density
    val w = (52 * d).toInt()
    val h = (64 * d).toInt()
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val p = Paint(Paint.ANTI_ALIAS_FLAG)
    val r = w / 2f
    // Pointer
    p.color = 0xFFFFFFFF.toInt()
    val tip = Path().apply {
        moveTo(r - 9 * d, r * 1.6f); lineTo(r + 9 * d, r * 1.6f); lineTo(r, h.toFloat()); close()
    }
    p.setShadowLayer(4 * d, 0f, 1.5f * d, 0x55000000)
    c.drawPath(tip, p)
    c.drawCircle(r, r, r - 2 * d, p)
    p.clearShadowLayer()
    // Colored face
    p.color = if (dim) 0xFF8A8F98.toInt() else color
    c.drawCircle(r, r, r - 5 * d, p)
    // Initial
    p.color = 0xFFFFFFFF.toInt()
    p.textSize = 22 * d
    p.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    p.textAlign = Paint.Align.CENTER
    val letter = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
    val fm = p.fontMetrics
    c.drawText(letter, r, r - (fm.ascent + fm.descent) / 2, p)
    return BitmapDrawable(ctx.resources, bmp)
}

@Composable
fun PeopleMap(
    people: List<Person>,
    myUid: String?,
    members: List<String>,
    focus: Focus?,
    onTapPerson: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val ctx = LocalContext.current
    val map = remember {
        MapView(ctx).apply {
            setTileSource(TileSourceFactory.MAPNIK)
            setMultiTouchControls(true)
            zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
            isTilesScaledToDpi = true
            setMinZoomLevel(3.0)
            setMaxZoomLevel(19.0)
            controller.setZoom(4.0)
            controller.setCenter(GeoPoint(39.5, -95.0))
        }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_RESUME -> map.onResume()
                Lifecycle.Event.ON_PAUSE -> map.onPause()
                else -> {}
            }
        }
        lifecycle.addObserver(obs)
        onDispose {
            lifecycle.removeObserver(obs)
            map.onDetach()
        }
    }

    AndroidView(factory = { map }, modifier = modifier)

    // Redraw pins whenever positions change.
    LaunchedEffect(people, myUid, members) {
        map.overlays.clear()
        val now = System.currentTimeMillis()
        // You first, so your partner's pin sits on top.
        val ordered = people.sortedBy { if (it.uid == myUid) 0 else 1 }
        for (person in ordered) {
            val pt = GeoPoint(person.lat, person.lng)
            val color = personColor(person.uid, myUid, members)
            if (person.accuracy > 30) {
                map.overlays.add(Polygon(map).apply {
                    setPoints(Polygon.pointsAsCircle(pt, person.accuracy))
                    fillPaint.color = (color and 0x00FFFFFF) or 0x22000000
                    outlinePaint.color = (color and 0x00FFFFFF) or 0x66000000
                    outlinePaint.strokeWidth = 2f
                    setOnClickListener { _, _, _ -> false }
                })
            }
            val stale = !person.sharing || now - person.updated > 60 * 60_000L
            map.overlays.add(Marker(map).apply {
                position = pt
                icon = avatar(ctx, if (person.uid == myUid) "Me" else person.name, color, stale)
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                setOnMarkerClickListener { _, _ -> onTapPerson(person.uid); true }
            })
        }
        map.invalidate()
    }

    // Move the camera when asked.
    LaunchedEffect(focus, people.isEmpty()) {
        if (focus == null || people.isEmpty()) return@LaunchedEffect
        val target = focus.uid?.let { id -> people.firstOrNull { it.uid == id } }
        map.post {
            if (target != null || people.size == 1) {
                val p = target ?: people.first()
                map.controller.animateTo(GeoPoint(p.lat, p.lng), 16.5, 700L)
            } else {
                val box = BoundingBox.fromGeoPointsSafe(people.map { GeoPoint(it.lat, it.lng) })
                val spanTiny = box.latitudeSpan < 0.003 && box.longitudeSpanWithDateLine < 0.003
                if (spanTiny) {
                    map.controller.animateTo(box.centerWithDateLine, 16.5, 700L)
                } else {
                    map.zoomToBoundingBox(box.increaseByScale(1.5f), true, (64 * ctx.resources.displayMetrics.density).toInt())
                }
            }
        }
    }
}
