plugins {
    id("com.android.application") version "8.9.1" apply false
    id("com.android.test") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.20" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.3.20" apply false
}

// iCloud Drive forbids hard links, which the Android resource merger relies on,
// and syncing build intermediates through iCloud wastes bandwidth. When the
// checkout lives under Mobile Documents, keep all build output on local disk.
// Worktrees need separate outputs even when their root project names match.
if (rootDir.absolutePath.contains("/Mobile Documents/")) {
    val checkoutId = java.security.MessageDigest.getInstance("SHA-256")
        .digest(rootDir.canonicalPath.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
    val localBuildRoot = File(
        System.getProperty("user.home"),
        ".gradle-builds/${rootProject.name}/$checkoutId"
    )
    allprojects {
        // Flat identities keep a parent's clean task from deleting a child's output.
        val projectDirectory = java.security.MessageDigest.getInstance("SHA-256")
            .digest(path.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        layout.buildDirectory.set(File(localBuildRoot, projectDirectory))
    }
}
