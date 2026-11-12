@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.music.bitchord.data.innertube

import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileModificationDate
import platform.Foundation.NSFileSize
import platform.Foundation.NSNumber
import platform.Foundation.NSString
import platform.Foundation.NSURL
import platform.Foundation.NSUserDomainMask
import platform.Foundation.create
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.timeIntervalSinceReferenceDate
import platform.Foundation.NSDate
import platform.Foundation.writeToFile

/**
 * One file per preprocessed player in the caches directory, which the OS may
 * reclaim; a missing file only means the next solve derives it again. YouTube
 * serves one player at a time, so a few entries cover a rollover.
 */
internal actual object PreprocessedPlayerStore {
    private const val DIRECTORY = "cipher-preprocessed"
    private const val MAX_ENTRIES = 3
    private const val MAX_BYTES = 16L * 1024 * 1024
    private const val UTF8 = 4uL // NSUTF8StringEncoding

    /** The library's key is a hex SHA-1; anything else is never a filename. */
    private val KEY = Regex("^[0-9a-f]{40}$")

    actual fun read(key: String): String? {
        val path = entryPath(key) ?: return null
        val manager = NSFileManager.defaultManager
        if (!manager.fileExistsAtPath(path)) return null
        val size = (manager.attributesOfItemAtPath(path, null)?.get(NSFileSize) as? NSNumber)?.longLongValue
        if (size == null || size <= 0 || size > MAX_BYTES) {
            manager.removeItemAtPath(path, null)
            return null
        }
        return NSString.stringWithContentsOfFile(path, UTF8, null)?.toString()
    }

    actual fun write(key: String, value: String?) {
        val path = entryPath(key) ?: return
        if (value == null) {
            NSFileManager.defaultManager.removeItemAtPath(path, null)
            return
        }
        NSString.create(string = value).writeToFile(path, true, UTF8, null)
        prune()
    }

    private fun prune() {
        val root = directory() ?: return
        val manager = NSFileManager.defaultManager
        val names = (manager.contentsOfDirectoryAtPath(root, null) as? List<*>)
            ?.filterIsInstance<String>() ?: return
        if (names.size <= MAX_ENTRIES) return
        names
            .map { name ->
                val modified = manager.attributesOfItemAtPath("$root/$name", null)
                    ?.get(NSFileModificationDate) as? NSDate
                name to (modified?.timeIntervalSinceReferenceDate ?: 0.0)
            }
            .sortedBy { it.second }
            .take(names.size - MAX_ENTRIES)
            .forEach { (name, _) -> manager.removeItemAtPath("$root/$name", null) }
    }

    private fun entryPath(key: String): String? =
        if (KEY.matches(key)) directory()?.let { "$it/$key.js" } else null

    private fun directory(): String? {
        val base = NSFileManager.defaultManager.URLsForDirectory(NSCachesDirectory, NSUserDomainMask)
            .firstOrNull() as? NSURL ?: return null
        val directory = "${base.path ?: return null}/$DIRECTORY"
        val manager = NSFileManager.defaultManager
        if (!manager.fileExistsAtPath(directory)) {
            manager.createDirectoryAtPath(directory, withIntermediateDirectories = true, attributes = null, error = null)
        }
        return directory
    }
}
