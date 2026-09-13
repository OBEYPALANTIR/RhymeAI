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
if (rootDir.absolutePath.contains("/Mobile Documents/")) {
    val localBuildRoot = File(
        System.getProperty("user.home"),
        ".gradle-builds/${rootProject.name}"
    )
    allprojects {
        layout.buildDirectory.set(File(localBuildRoot, if (this == rootProject) "root" else name))
    }
}
