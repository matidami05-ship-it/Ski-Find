package com.ski.find

import android.Manifest
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.Locale

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(
                colorScheme = darkColorScheme(
                    primary = Color(0xFF4C94F5),
                    secondary = Color(0xFF36B37E),
                    background = Color(0xFF0F1420),
                    surface = Color(0xFF171D2B),
                    surfaceVariant = Color(0xFF222A3B),
                )
            ) {
                App(vm)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        vm.startPolling()
        LocationService.start(this) // fresh position whenever the app opens
    }

    override fun onStop() {
        vm.stopPolling()
        super.onStop()
    }
}

@Composable
private fun App(vm: AppViewModel) {
    val s by vm.state.collectAsStateWithLifecycle()
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when {
            !s.ready -> {}
            s.circle == null -> SetupScreen(s, vm)
            else -> MainScreen(s, vm)
        }
    }
}

// ---------------- Setup ----------------

@Composable
private fun SetupScreen(s: UiState, vm: AppViewModel) {
    var name by remember { mutableStateOf(s.myName) }
    var code by remember { mutableStateOf("") }
    Column(
        Modifier
            .fillMaxSize()
            .systemBarsPadding()
            .imePadding()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier
                .size(72.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.primary),
            contentAlignment = Alignment.Center
        ) { Icon(Icons.Filled.LocationOn, null, tint = Color.White, modifier = Modifier.size(40.dp)) }
        Spacer(Modifier.height(20.dp))
        Text("Ski Find", fontSize = 32.sp, fontWeight = FontWeight.Bold)
        Text(
            "See each other on a live map, Samsung and iPhone.",
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(28.dp))
        OutlinedTextField(
            value = name, onValueChange = { name = it.take(30) },
            label = { Text("Your name") }, singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(Modifier.height(16.dp))
        Button(
            onClick = { vm.create(name) },
            enabled = name.isNotBlank() && !s.busy,
            modifier = Modifier.fillMaxWidth().height(52.dp)
        ) { Text("Start sharing (get a pair code)") }

        Spacer(Modifier.height(28.dp))
        Text("Already have a code from the other phone?", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = code, onValueChange = { code = it.uppercase().filter { c -> c.isLetterOrDigit() }.take(6) },
                label = { Text("Pair code") }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(12.dp))
            FilledTonalButton(
                onClick = { vm.join(name, code) },
                enabled = name.isNotBlank() && code.length == 6 && !s.busy,
                modifier = Modifier.height(56.dp)
            ) { Text("Join") }
        }
        if (s.busy) {
            Spacer(Modifier.height(20.dp))
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        s.error?.let {
            Spacer(Modifier.height(16.dp))
            Text(it, color = MaterialTheme.colorScheme.error)
        }
    }
}

// ---------------- Main map ----------------

private data class Perms(val location: Boolean, val background: Boolean, val notifications: Boolean, val battery: Boolean)

private fun readPerms(ctx: Context): Perms {
    val notif = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    val pm = ctx.getSystemService(PowerManager::class.java)
    return Perms(
        location = LocationService.hasForeground(ctx),
        background = LocationService.hasBackground(ctx),
        notifications = notif,
        battery = pm?.isIgnoringBatteryOptimizations(ctx.packageName) ?: true,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MainScreen(s: UiState, vm: AppViewModel) {
    val ctx = LocalContext.current
    var perms by remember { mutableStateOf(readPerms(ctx)) }
    var focus by remember { mutableStateOf<Focus?>(null) }
    var didInitialFocus by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showPair by remember { mutableStateOf(false) }

    // Re-check permissions every time we come back from Settings.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_RESUME) {
                perms = readPerms(ctx)
                LocationService.start(ctx)
            }
        }
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs) }
    }

    // First time positions arrive, fit everyone on screen.
    LaunchedEffect(s.people.isNotEmpty()) {
        if (s.people.isNotEmpty() && !didInitialFocus) {
            didInitialFocus = true
            focus = Focus(null)
        }
    }

    val locationLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        perms = readPerms(ctx)
        LocationService.start(ctx)
    }
    val backgroundLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        perms = readPerms(ctx)
        if (!it) openAppSettings(ctx)
        LocationService.start(ctx)
    }
    val notifLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        perms = readPerms(ctx)
    }

    val members = s.circle?.members.orEmpty()
    val alone = members.size == 1 || (members.isEmpty() && s.people.size <= 1)

    Box(Modifier.fillMaxSize()) {
        PeopleMap(
            people = s.people,
            myUid = s.myUid,
            members = members,
            photos = s.photos,
            focus = focus,
            onTapPerson = { focus = Focus(it) },
            modifier = Modifier.fillMaxSize()
        )

        // Top bar
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f), shadowElevation = 4.dp) {
                Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.LocationOn, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Ski Find", fontWeight = FontWeight.SemiBold)
                    if (!s.sharing) {
                        Spacer(Modifier.width(8.dp))
                        Text("· paused", color = Color(0xFFF2C94C), fontSize = 13.sp)
                    } else if (s.offline) {
                        Spacer(Modifier.width(8.dp))
                        Text("· offline", color = Color(0xFFF2994A), fontSize = 13.sp)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            RoundButton(Icons.Filled.ZoomOutMap, "Show everyone") { focus = Focus(null); vm.refreshNow() }
            Spacer(Modifier.width(8.dp))
            RoundButton(Icons.Filled.Settings, "Settings") { showSettings = true }
        }

        // Bottom panel
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            when {
                !perms.location -> SetupCard(
                    "Allow location",
                    "So your partner can see where you are.",
                    "Allow"
                ) {
                    locationLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                }
                !perms.background -> SetupCard(
                    "Share when the app is closed",
                    "On the next screen pick \"Allow all the time\".",
                    "Open"
                ) { backgroundLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION) }
                !perms.notifications -> SetupCard(
                    "Allow notifications",
                    "Android shows a small \"Sharing location\" notice while sharing.",
                    "Allow"
                ) { notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }
                !perms.battery -> SetupCard(
                    "Keep sharing reliable",
                    "Let Ski Find run in the background so Samsung's battery saver doesn't pause it.",
                    "Allow"
                ) { askIgnoreBattery(ctx) }
                else -> {}
            }

            s.update?.let { u ->
                Surface(shape = RoundedCornerShape(18.dp), color = Color(0xFF1F3B2E), shadowElevation = 6.dp) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.SystemUpdate, null, tint = Color(0xFF6FCF97))
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text("Update available", fontWeight = FontWeight.SemiBold)
                            Text(s.updateStatus ?: "Build ${u.build}", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Spacer(Modifier.width(8.dp))
                        Button(onClick = { vm.installUpdate(ctx) }, enabled = !s.updateBusy) { Text("Install") }
                    }
                }
            }

            val pairCode = s.circle?.joinCode.orEmpty()
            if (alone && pairCode.isNotEmpty()) {
                PairCard(pairCode) { shareCode(ctx, pairCode) }
            }

            val sorted = s.people.sortedBy { if (it.uid == s.myUid) 1 else 0 }
            if (sorted.isEmpty() && !alone) {
                Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface, shadowElevation = 6.dp) {
                    Text("Waiting for locations…", Modifier.padding(18.dp).fillMaxWidth(), textAlign = TextAlign.Center)
                }
            }
            if (sorted.isNotEmpty()) {
                Surface(shape = RoundedCornerShape(22.dp), color = MaterialTheme.colorScheme.surface, shadowElevation = 8.dp) {
                    LazyColumn(Modifier.heightIn(max = 330.dp).padding(vertical = 6.dp)) {
                        items(sorted, key = { it.uid }) { p ->
                            val me = sorted.firstOrNull { it.uid == s.myUid }
                            PersonRow(
                                p = p,
                                isMe = p.uid == s.myUid,
                                color = Color(personColor(p.uid, s.myUid, members)),
                                address = s.addresses[p.uid],
                                photo = s.photos[p.uid],
                                distanceFromMe = if (me != null && p.uid != s.myUid) distanceMeters(me, p) else null,
                                onShow = { focus = Focus(p.uid) },
                                onDirections = { openDirections(ctx, p) },
                            )
                        }
                    }
                }
            }
        }
    }

    if (showSettings) {
        ModalBottomSheet(onDismissRequest = { showSettings = false }) {
            SettingsSheet(s, vm, onShowCode = { showPair = true }, onClose = { showSettings = false })
        }
    }
    if (showPair) {
        AlertDialog(
            onDismissRequest = { showPair = false },
            confirmButton = { TextButton({ shareCode(ctx, s.circle?.joinCode ?: ""); showPair = false }) { Text("Share") } },
            dismissButton = { TextButton({ showPair = false }) { Text("Done") } },
            title = { Text("Pair code") },
            text = {
                Column {
                    Text(s.circle?.joinCode ?: "", fontSize = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = 6.sp)
                    Spacer(Modifier.height(8.dp))
                    Text("On the other phone, open Ski Find, enter a name and this code, then tap Join.")
                }
            }
        )
    }
}

@Composable
private fun RoundButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
        shadowElevation = 4.dp,
        modifier = Modifier.size(44.dp).clickable(onClick = onClick)
    ) {
        Box(contentAlignment = Alignment.Center) { Icon(icon, label) }
    }
}

@Composable
private fun SetupCard(title: String, body: String, action: String, onClick: () -> Unit) {
    Surface(shape = RoundedCornerShape(18.dp), color = Color(0xFF2B3550), shadowElevation = 6.dp) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Info, null, tint = Color(0xFFF2C94C))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.SemiBold)
                Text(body, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(8.dp))
            Button(onClick = onClick) { Text(action) }
        }
    }
}

@Composable
private fun PairCard(code: String, onShare: () -> Unit) {
    Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface, shadowElevation = 6.dp) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Waiting for the other phone", fontWeight = FontWeight.SemiBold)
                Text("Enter this code in Ski Find on the other phone:", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(code, fontSize = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = 5.sp)
            }
            FilledTonalButton(onClick = onShare) { Text("Share") }
        }
    }
}

@Composable
private fun PersonRow(
    p: Person,
    isMe: Boolean,
    color: Color,
    address: String?,
    photo: android.graphics.Bitmap?,
    distanceFromMe: Double?,
    onShow: () -> Unit,
    onDirections: () -> Unit,
) {
    val now = System.currentTimeMillis()
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onShow)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Avatar(p.name, photo, color, 46.dp, dim = !p.sharing)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(if (isMe) "${p.name} (you)" else p.name, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                address ?: String.format(Locale.US, "%.5f, %.5f", p.lat, p.lng),
                fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.85f)
            )
            val bits = buildList {
                add(if (!p.sharing) "Paused sharing" else timeAgo(p.updated, now))
                distanceFromMe?.let { add(formatDistance(it)) }
                if (p.speed > 4.5) add(String.format(Locale.US, "%.0f mph", p.speed * 2.23694))
                p.battery?.let { add("$it%" + if (p.charging) " ⚡" else " battery") }
            }
            Text(bits.joinToString(" · "), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (!isMe) {
            Spacer(Modifier.width(8.dp))
            FilledTonalButton(onClick = onDirections, contentPadding = PaddingValues(horizontal = 12.dp)) {
                Icon(Icons.Filled.Directions, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Drive")
            }
        }
    }
}

/** Someone's photo if they set one, otherwise their initial on their color. */
@Composable
fun Avatar(name: String, photo: android.graphics.Bitmap?, color: Color, size: Dp, dim: Boolean = false) {
    Box(
        Modifier.size(size).clip(CircleShape).background(if (dim) Color(0xFF8A8F98) else color),
        contentAlignment = Alignment.Center
    ) {
        if (photo != null) {
            Image(
                bitmap = remember(photo) { photo.asImageBitmap() },
                contentDescription = name,
                contentScale = ContentScale.Crop,
                colorFilter = if (dim) ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }) else null,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            Text(
                name.trim().take(1).uppercase().ifEmpty { "?" },
                color = Color.White, fontWeight = FontWeight.Bold, fontSize = (size.value * 0.43f).sp
            )
        }
    }
}

@Composable
private fun SettingsSheet(s: UiState, vm: AppViewModel, onShowCode: () -> Unit, onClose: () -> Unit) {
    val ctx = LocalContext.current
    var name by remember { mutableStateOf(s.myName) }
    var confirmLeave by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf<String?>(null) }
    val circle = s.circle
    var joinCode by remember { mutableStateOf("") }
    val myPhoto = s.myUid?.let { s.photos[it] }
    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) vm.setMyPhoto(uri)
    }

    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text("Settings", fontSize = 22.sp, fontWeight = FontWeight.Bold)

        Row(verticalAlignment = Alignment.CenterVertically) {
            Avatar(s.myName, myPhoto, Color(personColor(s.myUid ?: "", s.myUid, circle?.members.orEmpty())), 60.dp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text("Profile photo", fontWeight = FontWeight.SemiBold)
                Text("Shows on your pin on both phones.", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Column(horizontalAlignment = Alignment.End) {
                FilledTonalButton(onClick = {
                    pickPhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }, enabled = !s.busy) { Text(if (myPhoto == null) "Add" else "Change") }
                if (myPhoto != null) TextButton(onClick = { vm.removeMyPhoto() }, enabled = !s.busy) { Text("Remove") }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Share my location", fontWeight = FontWeight.SemiBold)
                Text(
                    if (s.sharing) "Your partner can see where you are." else "Paused. Your partner sees your last spot as paused.",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(checked = s.sharing, onCheckedChange = { vm.setSharing(it) })
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = name, onValueChange = { name = it.take(30) }, label = { Text("Your name") },
                singleLine = true, modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(10.dp))
            FilledTonalButton(onClick = { vm.rename(name) }, enabled = name.isNotBlank() && name.trim() != s.myName) { Text("Save") }
        }

        HorizontalDivider()
        Text("People", fontWeight = FontWeight.SemiBold)
        if (circle != null) circle.members.forEach { uid ->
            val n = circle.names[uid] ?: "Someone"
            Row(verticalAlignment = Alignment.CenterVertically) {
                Avatar(n, s.photos[uid], Color(personColor(uid, s.myUid, circle.members)), 32.dp)
                Spacer(Modifier.width(12.dp))
                Text(if (uid == s.myUid) "$n (you)" else n, Modifier.weight(1f))
                if (uid != s.myUid) TextButton({ confirmRemove = uid }) { Text("Remove") }
            }
        }
        Text("Join with a code", fontWeight = FontWeight.SemiBold)
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = joinCode,
                onValueChange = { joinCode = it.uppercase().filter { c -> c.isLetterOrDigit() }.take(6) },
                label = { Text("Code from the other phone") }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(10.dp))
            FilledTonalButton(
                onClick = { vm.switchTo(joinCode); joinCode = ""; onClose() },
                enabled = joinCode.length == 6 && joinCode != circle?.joinCode && !s.busy
            ) { Text("Join") }
        }
        OutlinedButton(onClick = onShowCode, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Filled.PersonAdd, null); Spacer(Modifier.width(8.dp)); Text("Pair code for another phone")
        }

        HorizontalDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("App version", fontWeight = FontWeight.SemiBold)
                Text(
                    s.updateStatus ?: "Build ${vm.currentBuild}",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (s.update != null) {
                Button(onClick = { vm.installUpdate(ctx) }, enabled = !s.updateBusy) { Text("Install") }
            } else {
                FilledTonalButton(onClick = { vm.checkForUpdate() }, enabled = !s.updateBusy) { Text("Check for updates") }
            }
        }

        HorizontalDivider()
        OutlinedButton(onClick = { openAppSettings(ctx) }, modifier = Modifier.fillMaxWidth()) {
            Text("App permissions")
        }
        TextButton(onClick = { confirmLeave = true }, modifier = Modifier.fillMaxWidth()) {
            Text("Stop sharing and leave", color = MaterialTheme.colorScheme.error)
        }
        s.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }

    if (confirmLeave) {
        AlertDialog(
            onDismissRequest = { confirmLeave = false },
            confirmButton = { TextButton({ confirmLeave = false; onClose(); vm.leave() }) { Text("Leave") } },
            dismissButton = { TextButton({ confirmLeave = false }) { Text("Cancel") } },
            title = { Text("Leave Ski Find?") },
            text = { Text("Your location is removed and sharing stops on this phone. You can pair again later with a code.") }
        )
    }
    confirmRemove?.let { uid ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            confirmButton = { TextButton({ confirmRemove = null; vm.removeMember(uid) }) { Text("Remove") } },
            dismissButton = { TextButton({ confirmRemove = null }) { Text("Cancel") } },
            title = { Text("Remove ${circle?.names?.get(uid) ?: "this person"}?") },
            text = { Text("They'll stop seeing your location and you'll stop seeing theirs. They can rejoin with the pair code.") }
        )
    }
}

// ---------------- Helpers ----------------

private fun timeAgo(t: Long, now: Long): String {
    if (t <= 0) return "Updating…"
    val m = (now - t) / 60_000
    return when {
        m < 1 -> "Now"
        m < 60 -> "$m min ago"
        m < 24 * 60 -> "${m / 60} hr ago"
        else -> "${m / (24 * 60)} days ago"
    }
}

private fun distanceMeters(a: Person, b: Person): Double {
    val out = FloatArray(1)
    android.location.Location.distanceBetween(a.lat, a.lng, b.lat, b.lng, out)
    return out[0].toDouble()
}

private fun formatDistance(m: Double): String {
    val miles = m / 1609.344
    return when {
        miles < 0.1 -> "${(m * 3.28084).toInt()} ft away"
        miles < 10 -> String.format(Locale.US, "%.1f mi away", miles)
        else -> String.format(Locale.US, "%.0f mi away", miles)
    }
}

private fun openDirections(ctx: Context, p: Person) {
    val nav = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=${p.lat},${p.lng}"))
        .setPackage("com.google.android.apps.maps")
    try {
        ctx.startActivity(nav)
    } catch (e: ActivityNotFoundException) {
        val label = Uri.encode(p.name)
        ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:${p.lat},${p.lng}?q=${p.lat},${p.lng}($label)")))
    }
}

private fun shareCode(ctx: Context, code: String) {
    val text = "Join me on Ski Find: open the app, enter your name and the pair code $code, then tap Join."
    ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "Share pair code"))
}

private fun openAppSettings(ctx: Context) {
    ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null)))
}

@SuppressLint("BatteryLife")
private fun askIgnoreBattery(ctx: Context) {
    try {
        ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}")))
    } catch (e: Exception) {
        ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }
}
