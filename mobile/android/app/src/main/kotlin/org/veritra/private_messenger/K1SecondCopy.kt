package org.veritra.private_messenger

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * K1 second copy on Android (docs/designs/K1-automatic-backups.md, "Second
 * copy"; D91). The user picks a folder with ACTION_OPEN_DOCUMENT_TREE; the
 * app keeps the persistable grant and replaces one file there after each
 * backup. The file is ciphertext that opens only with the recovery key. No
 * storage permission is declared: the grant covers the picked tree only.
 *
 * "write" and "release" need no Activity, so they are answered here even
 * while the UI is being recreated; only "pickFolder" goes to [MainActivity].
 * Errors carry a code and an exception class name, never a path or a name.
 */
object K1SecondCopy {
    const val CHANNEL = "org.veritra.private_messenger/k1_second_copy"
    const val PICK_REQUEST = 4103
    const val GRANT = Intent.FLAG_GRANT_READ_URI_PERMISSION or
        Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    // Tens of megabytes must not be written on the main thread.
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun install(app: Context, messenger: BinaryMessenger, activity: () -> MainActivity?) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "write" -> {
                    val tree = call.argument<String>("tree")
                    val name = call.argument<String>("name")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (tree.isNullOrBlank() || name == null || !validName(name) || bytes == null) {
                        result.error("invalid_arguments", null, null)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        val failure = try {
                            write(app, Uri.parse(tree), name, bytes)
                            null
                        } catch (err: Exception) {
                            err.javaClass.simpleName
                        }
                        main.post {
                            if (failure == null) result.success(null)
                            else result.error("write_failed", null, failure)
                        }
                    }
                }
                "release" -> {
                    val tree = call.argument<String>("tree")
                    if (!tree.isNullOrBlank()) {
                        try {
                            app.contentResolver.releasePersistableUriPermission(Uri.parse(tree), GRANT)
                        } catch (_: SecurityException) {
                            // Not held (already released or revoked): nothing to do.
                        }
                    }
                    result.success(null)
                }
                "pickFolder" -> activity()?.pickK1Folder(result)
                    ?: result.error("ui_unavailable", null, null)
                else -> result.notImplemented()
            }
        }
    }

    /** The file names Dart sends: `veritra-backup-<ids>.vhc`, safe characters. */
    fun validName(name: String): Boolean =
        Regex("\\Averitra-backup-[A-Za-z0-9_-]{1,200}\\.vhc\\z").matches(name)

    /** The picked folder's display name, for Settings (never the URI). */
    fun label(context: Context, tree: Uri): String? = try {
        val folder = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree))
        context.contentResolver.query(
            folder, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    /**
     * Replaces [name] in [tree] with [bytes]. The storage framework has no
     * atomic replace, so the order keeps one complete copy at every point:
     * the new file is written in full as `<name>.part` and synced, then the
     * old file is deleted, then the new one is renamed. A failure before the
     * delete removes the temporary file and keeps the old copy; a failed
     * rename after it keeps the complete `.part` until the next run, which
     * replaces it (the warning shows meanwhile). A provider that cannot
     * rename gets the file written in place instead.
     */
    @Throws(IOException::class)
    fun write(context: Context, tree: Uri, name: String, bytes: ByteArray) {
        val resolver = context.contentResolver
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree))
        val part = "$name.part"
        // A leftover temporary file would make the provider name the new
        // one "<name>.part (1)".
        find(resolver, tree, part)?.let { DocumentsContract.deleteDocument(resolver, it) }
        val temp = DocumentsContract.createDocument(
            resolver, parent, "application/octet-stream", part,
        ) ?: throw IOException("create")
        var oldDeleted = false
        try {
            writeAll(resolver, temp, bytes)
            if (!supportsRename(resolver, temp)) {
                DocumentsContract.deleteDocument(resolver, temp)
                val target = find(resolver, tree, name)
                    ?: DocumentsContract.createDocument(
                        resolver, parent, "application/octet-stream", name)
                    ?: throw IOException("create")
                writeAll(resolver, target, bytes)
                return
            }
            find(resolver, tree, name)?.let {
                if (!DocumentsContract.deleteDocument(resolver, it)) throw IOException("delete")
            }
            oldDeleted = true
            DocumentsContract.renameDocument(resolver, temp, name) ?: throw IOException("rename")
        } catch (err: Exception) {
            if (!oldDeleted) {
                try {
                    DocumentsContract.deleteDocument(resolver, temp)
                } catch (_: Exception) {}
            }
            throw err
        }
    }

    private fun writeAll(resolver: ContentResolver, document: Uri, bytes: ByteArray) {
        val descriptor = resolver.openFileDescriptor(document, "wt") ?: throw IOException("open")
        descriptor.use { pfd ->
            FileOutputStream(pfd.fileDescriptor).use { out ->
                out.write(bytes)
                out.flush()
                out.fd.sync()
            }
        }
    }

    private fun supportsRename(resolver: ContentResolver, document: Uri): Boolean =
        resolver.query(document, arrayOf(Document.COLUMN_FLAGS), null, null, null)?.use { cursor ->
            cursor.moveToFirst() &&
                (cursor.getInt(0) and Document.FLAG_SUPPORTS_RENAME) != 0
        } ?: false

    /** The child of [tree] whose display name is exactly [name]. Providers
     * ignore selection arguments, so every child is compared here. */
    private fun find(resolver: ContentResolver, tree: Uri, name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree))
        resolver.query(
            children,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
                }
            }
        }
        return null
    }
}
