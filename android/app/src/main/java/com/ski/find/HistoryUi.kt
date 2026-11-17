package com.ski.find

import android.graphics.Bitmap
import android.graphics.Canvas as ACanvas
import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import org.osmdroid.events.MapListener
import org.osmdroid.events.ScrollEvent
import org.osmdroid.events.ZoomEvent
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polygon
import org.osmdroid.views.overlay.Polyline
import java.text.DateFormat
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Date
import java.util.Locale

// ---------------- Formatting ----------------

private val timeFmt: DateFormat = DateFormat.getTimeInstance(DateFormat.SHORT)
fun clock(ms: Long): String = timeFmt.format(Date(ms))

fun duration(ms: Long): String {
    val m = (ms / 60_000).coerceAtLeast(1)
    return when {
        m < 60 -> "$m min"
        m % 60 == 0L -> "${m / 60} hr"
        else -> "${m / 60} hr ${m % 60} min"
    }
}

fun dayLabel(offset: Int): String = when (offset) {
    0 -> "Today"
    1 -> "Yesterday"
    else -> LocalDate.now().minusDays(offset.toLong()).let {
        it.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault()) + " " + it.monthValue + "/" + it.dayOfMonth
    }
}

private fun miles(m: Double): String {
    val mi = m / 1609.344
    return if (mi < 0.1) "${(m * 3.28084).toInt()} ft" else String.format(Locale.US, "%.1f mi", mi)
}

private fun dot(ctx: android.content.Context, color: Int, sizeDp: Int = 14): BitmapDrawable {
    val d = ctx.resources.displayMetrics.density
    val px = (sizeDp * d).toInt()
    val bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
    val c = ACanvas(bmp)
    val p = Paint(Paint.ANTI_ALIAS_FLAG)
    p.color = 0xFFFFFFFF.toInt()
    c.drawCircle(px / 2f, px / 2f, px / 2f, p)
    p.color = color
    c.drawCircle(px / 2f, px / 2f, px / 2f - 2.5f * d, p)
    return BitmapDrawable(ctx.resources, bmp)
}

private fun newMap(ctx: android.content.Context) = MapView(ctx).apply {
    setTileSource(TileSourceFactory.MAPNIK)
    setMultiTouchControls(true)
    zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
    isTilesScaledToDpi = true
    setMinZoomLevel(3.0)
    setMaxZoomLevel(19.0)
    onResume()
}

// ---------------- History sheet ----------------

@Composable
fun HistorySheet(s: UiState, vm: AppViewModel, onDirections: (Person) -> Unit) {
    val h = s.history ?: return
    val person = s.people.firstOrNull { it.uid == h.uid }
    val name = person?.name ?: s.circle?.names?.get(h.uid) ?: "Someone"
    val isMe = h.uid == s.myUid
    val color = Color(personColor(h.uid, s.myUid, s.circle?.members.orEmpty()))

    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Avatar(name, s.photos[h.uid], color, 56.dp, dim = person?.sharing == false)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(if (isMe) "$name (you)" else name, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text(
                    s.addresses[h.uid] ?: "Location history",
                    fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (!isMe && person != null) {
                FilledTonalButton(onClick = { onDirections(person) }) {
                    Icon(Icons.Filled.Directions, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Drive")
                }
            }
        }

        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items((0..6).toList()) { i ->
                FilterChip(
                    selected = h.dayOffset == i,
                    onClick = { vm.openHistory(h.uid, i) },
                    label = { Text(dayLabel(i)) }
                )
            }
        }

        Box(
            Modifier
                .fillMaxWidth()
                .height(240.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
        ) {
            HistoryMap(h.points, h.segments.filterIsInstance<Segment.Stay>(), color.toArgbInt())
            if (h.loading) CircularProgressIndicator(Modifier.align(Alignment.Center))
        }

        when {
            h.error != null -> Text(h.error, color = MaterialTheme.colorScheme.error)
            !h.loading && h.segments.isEmpty() -> Text(
                if (h.points.isEmpty()) "No location history for ${dayLabel(h.dayOffset).lowercase()}."
                else "Stayed close to one spot.",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        LazyColumn(Modifier.heightIn(max = 380.dp)) {
            items(h.segments.reversed()) { seg -> SegmentRow(seg, vm) }
        }
    }
}

private fun Color.toArgbInt(): Int =
    ((alpha * 255).toInt() shl 24) or ((red * 255).toInt() shl 16) or ((green * 255).toInt() shl 8) or (blue * 255).toInt()

@Composable
private fun SegmentRow(seg: Segment, vm: AppViewModel) {
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier.size(40.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                if (seg is Segment.Stay) Icons.Filled.Place else Icons.Filled.DirectionsCar, null,
                tint = if (seg is Segment.Stay) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            when (seg) {
                is Segment.Stay -> {
                    val label by produceState<String?>(null, seg.lat, seg.lng) { value = vm.label(seg.lat, seg.lng) }
                    Text(label ?: "Stop", fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        if (seg.ongoing) "Since ${clock(seg.start)} · ${duration(seg.end - seg.start)}"
                        else "${clock(seg.start)} – ${clock(seg.end)} · ${duration(seg.end - seg.start)}",
                        fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                is Segment.Move -> {
                    Text(if (seg.ongoing) "On the move" else "Drive / trip", fontWeight = FontWeight.SemiBold)
                    Text(
                        "${clock(seg.start)} – ${clock(seg.end)} · ${duration(seg.end - seg.start)} · ${miles(seg.meters)}",
                        fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun HistoryMap(points: List<HistPoint>, stays: List<Segment.Stay>, color: Int) {
    val ctx = LocalContext.current
    val map = remember { newMap(ctx) }
    DisposableEffect(Unit) { onDispose { map.onDetach() } }
    AndroidView(factory = { map }, modifier = Modifier.fillMaxSize())
    LaunchedEffect(points, stays) {
        map.overlays.clear()
        if (points.isEmpty()) {
            map.invalidate()
            return@LaunchedEffect
        }
        val geo = points.map { GeoPoint(it.lat, it.lng) }
        if (geo.size > 1) {
            map.overlays.add(Polyline(map).apply {
                setPoints(geo)
                outlinePaint.color = color
                outlinePaint.strokeWidth = 5f * ctx.resources.displayMetrics.density
                outlinePaint.strokeCap = Paint.Cap.ROUND
                setOnClickListener { _, _, _ -> false }
            })
        }
        for (s in stays) {
            map.overlays.add(Marker(map).apply {
                position = GeoPoint(s.lat, s.lng)
                icon = dot(ctx, color, 16)
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                setOnMarkerClickListener { _, _ -> true }
            })
        }
        map.overlays.add(Marker(map).apply {
            position = geo.last()
            icon = dot(ctx, 0xFFFFFFFF.toInt(), 12)
            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
            setOnMarkerClickListener { _, _ -> true }
        })
        map.invalidate()
        map.post {
            val box = BoundingBox.fromGeoPointsSafe(geo)
            if (box.latitudeSpan < 0.004 && box.longitudeSpanWithDateLine < 0.004) {
                map.controller.setZoom(16.0)
                map.controller.setCenter(box.centerWithDateLine)
            } else {
                map.zoomToBoundingBox(box.increaseByScale(1.3f), false, (24 * ctx.resources.displayMetrics.density).toInt())
            }
        }
    }
}

// ---------------- Places (Settings) ----------------

@Composable
fun PlacesSection(s: UiState, vm: AppViewModel) {
    var editing by remember { mutableStateOf<Place?>(null) }
    var adding by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf<Place?>(null) }

    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Arrive & leave alerts", fontWeight = FontWeight.SemiBold)
            Text(
                "Get notified when someone arrives at or leaves a place below.",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Switch(checked = s.alerts, onCheckedChange = { vm.setAlerts(it) })
    }
    Text("Places", fontWeight = FontWeight.SemiBold)
    if (s.places.isEmpty()) {
        Text("No places yet. Add Home, Work or anywhere else.", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    s.places.forEach { p ->
        Row(
            Modifier.fillMaxWidth().clickable { editing = p }.padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(placeIcon(p.name), null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(p.name)
                Text("${(p.radius * 3.28084).toInt()} ft around", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = { confirmDelete = p }) { Icon(Icons.Filled.Delete, "Delete ${p.name}") }
        }
    }
    OutlinedButton(onClick = { adding = true }, modifier = Modifier.fillMaxWidth()) {
        Icon(Icons.Filled.AddLocationAlt, null); Spacer(Modifier.width(8.dp)); Text("Add a place")
    }

    if (adding || editing != null) {
        val me = s.people.firstOrNull { it.uid == s.myUid } ?: s.people.firstOrNull()
        PlaceEditor(
            place = editing,
            startLat = editing?.lat ?: me?.lat ?: 42.59,
            startLng = editing?.lng ?: me?.lng ?: -88.43,
            onDismiss = { adding = false; editing = null },
            onSave = { name, lat, lng, r ->
                vm.savePlace(name, lat, lng, r, editing?.id)
                adding = false; editing = null
            }
        )
    }
    confirmDelete?.let { p ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            confirmButton = { TextButton({ vm.deletePlace(p.id); confirmDelete = null }) { Text("Delete") } },
            dismissButton = { TextButton({ confirmDelete = null }) { Text("Cancel") } },
            title = { Text("Delete ${p.name}?") },
            text = { Text("You'll stop getting alerts for this place on both phones.") }
        )
    }
}

fun placeIcon(name: String) = when {
    name.contains("home", true) -> Icons.Filled.Home
    name.contains("work", true) || name.contains("office", true) -> Icons.Filled.Work
    name.contains("school", true) -> Icons.Filled.School
    name.contains("gym", true) -> Icons.Filled.FitnessCenter
    else -> Icons.Filled.Place
}

@Composable
private fun PlaceEditor(
    place: Place?,
    startLat: Double,
    startLng: Double,
    onDismiss: () -> Unit,
    onSave: (String, Double, Double, Double) -> Unit,
) {
    val ctx = LocalContext.current
    var name by remember { mutableStateOf(place?.name ?: "") }
    var radius by remember { mutableFloatStateOf((place?.radius ?: 150.0).toFloat()) }
    var tick by remember { mutableIntStateOf(0) } // bumps when the map moves, to redraw the circle
    val map = remember {
        newMap(ctx).apply {
            controller.setZoom(17.0)
            controller.setCenter(GeoPoint(startLat, startLng))
            addMapListener(object : MapListener {
                override fun onScroll(event: ScrollEvent?): Boolean { tick++; return false }
                override fun onZoom(event: ZoomEvent?): Boolean { tick++; return false }
            })
        }
    }
    DisposableEffect(Unit) { onDispose { map.onDetach() } }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().systemBarsPadding().imePadding()) {
                Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    Text(
                        if (place == null) "Add a place" else "Edit place",
                        Modifier.weight(1f), fontWeight = FontWeight.Bold, fontSize = 18.sp,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center
                    )
                    TextButton(
                        onClick = {
                            val c = map.mapCenter
                            onSave(name, c.latitude, c.longitude, radius.toDouble())
                        },
                        enabled = name.isNotBlank()
                    ) { Text("Save") }
                }
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    AndroidView(factory = { map }, modifier = Modifier.fillMaxSize())
                    // The place is the middle of the map; the ring shows the alert area.
                    Canvas(Modifier.fillMaxSize()) {
                        tick // read so the ring follows the map
                        val px = map.projection.metersToPixels(radius) // screen pixels
                        drawCircle(Color(0x332F80ED), px, Offset(size.width / 2, size.height / 2))
                        drawCircle(Color(0xFF2F80ED), px, Offset(size.width / 2, size.height / 2), style = Stroke(3f))
                        drawCircle(Color(0xFF2F80ED), 9f, Offset(size.width / 2, size.height / 2))
                    }
                    Text(
                        "Move the map to put the place in the middle",
                        Modifier.align(Alignment.TopCenter).padding(10.dp)
                            .background(Color(0xCC0F1420), RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 6.dp),
                        fontSize = 13.sp
                    )
                }
                Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(listOf("Home", "Work", "School", "Gym")) { q ->
                            AssistChip(onClick = { name = q }, label = { Text(q) }, leadingIcon = { Icon(placeIcon(q), null, Modifier.size(18.dp)) })
                        }
                    }
                    OutlinedTextField(
                        value = name, onValueChange = { name = it.take(30) }, label = { Text("Name") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                        modifier = Modifier.fillMaxWidth()
                    )
                    Text("Alert area: ${(radius * 3.28084f).toInt()} ft around", fontSize = 13.sp)
                    Slider(value = radius, onValueChange = { radius = it }, valueRange = 75f..500f)
                }
            }
        }
    }
}
