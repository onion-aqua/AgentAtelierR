package com.example.ryza_chat_mvp

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Android package verification and installer bridge for the self-hosted updater.
 *
 * Candidate packages are only accepted from this application's private storage,
 * then copied into a narrow FileProvider directory after validation. The package
 * is validated again in installApk so a caller cannot bypass the checks by
 * replacing a file between inspection and installation.
 */
class ApkUpdateBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler(::handle)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInstallPermissionStatus" -> result.success(installPermissionStatus())
            "openInstallPermissionSettings" -> result.success(openInstallPermissionSettings())
            "getAvailableUpdateSpace" -> result.success(
                mapOf("bytes" to activity.filesDir.usableSpace),
            )
            "getInstalledAppInfo" -> runOnWorker(result) { installedAppInfo() }
            "prepareCurrentApk" -> runOnWorker(result) { prepareCurrentApk() }
            "validateApk" -> runOnWorker(result) {
                validateCandidate(call).toMap()
            }
            "installApk" -> runOnWorker(result) {
                requireInstallPermission()
                val candidate = validateCandidate(call)
                val staged = stageForInstall(candidate)
                mainHandler.post {
                    try {
                        result.success(launchInstaller(staged, candidate))
                    } catch (error: BridgeFailure) {
                        result.error(error.code, error.safeMessage, null)
                    } catch (_: Exception) {
                        result.error("installer_launch_failed", "Unable to open the Android package installer.", null)
                    }
                }
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun runOnWorker(
        result: MethodChannel.Result,
        block: () -> Map<String, Any?>?,
    ) {
        worker.execute {
            try {
                val value = block()
                if (value != null) mainHandler.post { result.success(value) }
            } catch (error: BridgeFailure) {
                mainHandler.post { result.error(error.code, error.safeMessage, null) }
            } catch (_: SecurityException) {
                mainHandler.post {
                    result.error("security_error", "Android rejected access to the update package.", null)
                }
            } catch (_: IOException) {
                mainHandler.post {
                    result.error("package_io_error", "Unable to read or stage the update package.", null)
                }
            } catch (_: Exception) {
                mainHandler.post {
                    result.error("native_error", "Android could not process the update package.", null)
                }
            }
        }
    }

    private fun installPermissionStatus(): Map<String, Any> {
        val required = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        val granted = !required || activity.packageManager.canRequestPackageInstalls()
        return mapOf(
            "required" to required,
            "granted" to granted,
        )
    }

    private fun openInstallPermissionSettings(): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf("opened" to false, "required" to false, "granted" to true)
        }
        if (activity.packageManager.canRequestPackageInstalls()) {
            return mapOf("opened" to false, "required" to true, "granted" to true)
        }
        val opened = try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
            true
        } catch (_: RuntimeException) {
            try {
                activity.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                true
            } catch (_: RuntimeException) {
                false
            }
        }
        return mapOf("opened" to opened, "required" to true, "granted" to false)
    }

    private fun prepareCurrentApk(): Map<String, Any?> {
        val packageInfo = currentPackageInfo(signatures = true)
        val certificateSha256 = currentCertificateSha256(packageInfo)
        val supportedAbis = Build.SUPPORTED_ABIS.toList()
        val appInfo = activity.applicationInfo
        if (!appInfo.splitSourceDirs.isNullOrEmpty()) {
            return unsupportedCurrentApk(
                "split_apk_install",
                packageInfo,
                certificateSha256,
                supportedAbis,
            )
        }
        val sourcePath = appInfo.sourceDir
        if (sourcePath.isNullOrEmpty()) {
            return unsupportedCurrentApk(
                "source_unavailable",
                packageInfo,
                certificateSha256,
                supportedAbis,
            )
        }
        val source = File(sourcePath)
        if (!source.isFile || !source.canRead()) {
            return unsupportedCurrentApk(
                "source_unreadable",
                packageInfo,
                certificateSha256,
                supportedAbis,
            )
        }
        val sourceSha256 = sha256(source)
        val destinationDir = File(activity.noBackupFilesDir, "updates/base")
        ensureDirectory(destinationDir)
        val destination = File(
            destinationDir,
            "base-${versionCode(packageInfo)}-${sourceSha256.take(16)}.apk",
        )
        if (!destination.isFile || destination.length() != source.length()) {
            if (destinationDir.usableSpace <= source.length() + MIN_FREE_SPACE_BYTES) {
                throw BridgeFailure("storage_insufficient", "There is not enough free space to prepare the current APK.")
            }
            copyAtomically(source, destination)
        }
        if (sha256(destination) != sourceSha256) {
            destination.delete()
            throw BridgeFailure("base_copy_mismatch", "The copied current APK failed integrity verification.")
        }
        return mapOf(
            "supported" to true,
            "reason" to null,
            "packageName" to activity.packageName,
            "versionCode" to versionCode(packageInfo),
            "versionName" to packageInfo.versionName,
            "certificateSha256" to certificateSha256,
            "supportedAbis" to supportedAbis,
            "supportedDeltaFormats" to emptyList<String>(),
            "apkPath" to destination.absolutePath,
            "sha256" to sourceSha256,
            "bytes" to destination.length(),
        )
    }

    private fun installedAppInfo(): Map<String, Any?> {
        val packageInfo = currentPackageInfo(signatures = true)
        return mapOf(
            "packageName" to activity.packageName,
            "versionCode" to versionCode(packageInfo),
            "versionName" to packageInfo.versionName,
            "certificateSha256" to currentCertificateSha256(packageInfo),
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            // No binary patch engine is bundled in the bootstrap release.
            "supportedDeltaFormats" to emptyList<String>(),
        )
    }

    private fun unsupportedCurrentApk(
        reason: String,
        packageInfo: PackageInfo,
        certificateSha256: String,
        supportedAbis: List<String>,
    ): Map<String, Any?> {
        return mapOf(
            "supported" to false,
            "reason" to reason,
            "packageName" to activity.packageName,
            "versionCode" to versionCode(packageInfo),
            "versionName" to packageInfo.versionName,
            "certificateSha256" to certificateSha256,
            "supportedAbis" to supportedAbis,
            "supportedDeltaFormats" to emptyList<String>(),
            "apkPath" to null,
            "sha256" to null,
            "bytes" to null,
        )
    }

    private fun validateCandidate(call: MethodCall): ValidatedApk {
        val path = call.argument<String>("path")?.trim().orEmpty()
        val expectedPackage = call.argument<String>("expectedPackageName")?.trim().orEmpty()
        val expectedVersion = (call.argument<Number>("expectedVersionCode"))?.toLong()
        val expectedSha256 = call.argument<String>("expectedSha256")?.trim()?.lowercase().orEmpty()
        if (path.isEmpty() || expectedPackage.isEmpty() || expectedVersion == null ||
            !SHA_256_PATTERN.matches(expectedSha256)
        ) {
            throw BridgeFailure("invalid_arguments", "APK path, package, version code, and SHA-256 are required.")
        }
        if (expectedPackage != activity.packageName) {
            throw BridgeFailure("expected_package_mismatch", "The update manifest targets a different application.")
        }
        val source = privateCandidateFile(path)
        if (!source.isFile || !source.canRead() || source.length() <= 0L) {
            throw BridgeFailure("apk_unreadable", "The downloaded APK is unavailable or unreadable.")
        }
        val actualSha256 = sha256(source)
        if (!actualSha256.equals(expectedSha256, ignoreCase = true)) {
            throw BridgeFailure("sha256_mismatch", "The downloaded APK failed integrity verification.")
        }
        val archiveInfo = archivePackageInfo(source)
            ?: throw BridgeFailure("invalid_apk", "Android could not read the downloaded APK.")
        if (archiveInfo.packageName != activity.packageName || archiveInfo.packageName != expectedPackage) {
            throw BridgeFailure("package_name_mismatch", "The downloaded APK belongs to a different application.")
        }
        val archiveVersion = versionCode(archiveInfo)
        val currentVersion = versionCode(currentPackageInfo())
        if (archiveVersion != expectedVersion) {
            throw BridgeFailure("version_code_mismatch", "The downloaded APK version does not match the update manifest.")
        }
        if (archiveVersion < currentVersion) {
            throw BridgeFailure("version_downgrade", "The downloaded APK is older than the installed version.")
        }
        if (!hasCompatibleSigningCertificate(currentPackageInfo(signatures = true), archiveInfo)) {
            throw BridgeFailure("signature_mismatch", "The downloaded APK is not signed for this installation.")
        }
        return ValidatedApk(
            source = source,
            packageName = archiveInfo.packageName,
            versionCode = archiveVersion,
            versionName = archiveInfo.versionName,
            sha256 = actualSha256,
            bytes = source.length(),
        )
    }

    private fun privateCandidateFile(path: String): File {
        val candidate = try {
            File(path).canonicalFile
        } catch (_: IOException) {
            throw BridgeFailure("apk_unreadable", "The downloaded APK path is invalid.")
        }
        if (!candidate.name.endsWith(".apk", ignoreCase = true)) {
            throw BridgeFailure("invalid_apk_path", "The update package must be an APK file.")
        }
        val roots = listOfNotNull(
            activity.filesDir,
            activity.cacheDir,
            activity.noBackupFilesDir,
            activity.getExternalFilesDir(null),
            activity.externalCacheDir,
        ).mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
        val insidePrivateStorage = roots.any { root ->
            candidate.path == root.path || candidate.path.startsWith(root.path + File.separator)
        }
        if (!insidePrivateStorage) {
            throw BridgeFailure("apk_path_not_allowed", "The update APK is outside application-managed storage.")
        }
        return candidate
    }

    private fun stageForInstall(candidate: ValidatedApk): File {
        val downloaderDirectory = File(activity.filesDir, "agent_atelier_updates_v1")
        if (isWithin(candidate.source, downloaderDirectory)) {
            return candidate.source
        }
        val installDir = File(activity.cacheDir, "updates/install")
        ensureDirectory(installDir)
        val staged = File(
            installDir,
            "update-${candidate.versionCode}-${candidate.sha256.take(16)}.apk",
        )
        val stagedIsValid = staged.isFile &&
            staged.length() == candidate.bytes &&
            sha256(staged) == candidate.sha256
        if (!stagedIsValid) {
            if (installDir.usableSpace <= candidate.bytes + MIN_FREE_SPACE_BYTES) {
                throw BridgeFailure("storage_insufficient", "There is not enough free space to stage the update APK.")
            }
            copyAtomically(candidate.source, staged)
        }
        if (sha256(staged) != candidate.sha256) {
            staged.delete()
            throw BridgeFailure("staged_apk_mismatch", "The staged APK failed integrity verification.")
        }
        return staged
    }

    private fun isWithin(candidate: File, directory: File): Boolean {
        val candidatePath = runCatching { candidate.canonicalFile.path }.getOrNull() ?: return false
        val directoryPath = runCatching { directory.canonicalFile.path }.getOrNull() ?: return false
        return candidatePath.startsWith(directoryPath + File.separator)
    }

    private fun launchInstaller(staged: File, candidate: ValidatedApk): Map<String, Any?> {
        requireInstallPermission()
        val uri = try {
            FileProvider.getUriForFile(activity, "${activity.packageName}.update_file_provider", staged)
        } catch (_: IllegalArgumentException) {
            throw BridgeFailure("file_provider_error", "The verified APK could not be shared with Android.")
        }
        val commonFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION
        val intents = listOf(
            Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                data = uri
                addFlags(commonFlags)
                putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
            },
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME_TYPE)
                addFlags(commonFlags)
            },
        )
        for (intent in intents) {
            intent.clipData = ClipData.newRawUri("AgentAtelierR update", uri)
            try {
                activity.startActivity(intent)
                return mapOf(
                    "launched" to true,
                    "packageName" to candidate.packageName,
                    "versionCode" to candidate.versionCode,
                    "versionName" to candidate.versionName,
                    "sha256" to candidate.sha256,
                    "bytes" to candidate.bytes,
                )
            } catch (_: RuntimeException) {
                // Try the broadly supported ACTION_VIEW fallback.
            }
        }
        throw BridgeFailure("installer_unavailable", "No Android package installer is available.")
    }

    @Suppress("DEPRECATION")
    private fun currentPackageInfo(signatures: Boolean = false): PackageInfo {
        val flags = when {
            !signatures -> 0L
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> PackageManager.GET_SIGNING_CERTIFICATES.toLong()
            else -> PackageManager.GET_SIGNATURES.toLong()
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.packageManager.getPackageInfo(
                activity.packageName,
                PackageManager.PackageInfoFlags.of(flags),
            )
        } else {
            activity.packageManager.getPackageInfo(activity.packageName, flags.toInt())
        }
    }

    @Suppress("DEPRECATION")
    private fun archivePackageInfo(apk: File): PackageInfo? {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES.toLong()
        } else {
            PackageManager.GET_SIGNATURES.toLong()
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.packageManager.getPackageArchiveInfo(
                apk.absolutePath,
                PackageManager.PackageInfoFlags.of(flags),
            )
        } else {
            activity.packageManager.getPackageArchiveInfo(apk.absolutePath, flags.toInt())
        }
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signerSet(info: PackageInfo): SignerSet {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return SignerSet(emptySet(), emptySet(), false)
            val current = signingInfo.apkContentsSigners.orEmpty().map(::certificateSha256).toSet()
            val multiple = signingInfo.hasMultipleSigners()
            val history = if (multiple) {
                current
            } else {
                signingInfo.signingCertificateHistory.orEmpty().map(::certificateSha256).toSet()
            }
            return SignerSet(current, history.ifEmpty { current }, multiple)
        }
        val current = info.signatures.orEmpty().map(::certificateSha256).toSet()
        return SignerSet(current, current, current.size > 1)
    }

    private fun hasCompatibleSigningCertificate(current: PackageInfo, candidate: PackageInfo): Boolean {
        val installed = signerSet(current)
        val update = signerSet(candidate)
        if (installed.current.isEmpty() || update.current.isEmpty()) return false
        if (installed.multiple || update.multiple) return installed.current == update.current
        return update.history.containsAll(installed.current)
    }

    private fun currentCertificateSha256(packageInfo: PackageInfo): String {
        val currentSigners = signerSet(packageInfo).current
        return currentSigners.singleOrNull()
            ?: throw BridgeFailure(
                "current_signature_unavailable",
                "The installed application's signing identity is unavailable or unsupported.",
            )
    }

    private fun requireInstallPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            throw BridgeFailure(
                "install_permission_required",
                "Allow this app to install updates, then try again.",
            )
        }
    }

    private fun certificateSha256(signature: android.content.pm.Signature): String =
        MessageDigest.getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString("") { "%02x".format(it) }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(COPY_BUFFER_BYTES)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count > 0) digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun copyAtomically(source: File, destination: File) {
        ensureDirectory(destination.parentFile ?: throw IOException("Missing destination directory"))
        val temporary = File.createTempFile("apk-update-", ".partial", destination.parentFile)
        try {
            FileInputStream(source).use { input ->
                FileOutputStream(temporary).use { output ->
                    input.copyTo(output, COPY_BUFFER_BYTES)
                    output.fd.sync()
                }
            }
            if (destination.exists() && !destination.delete()) {
                throw IOException("Unable to replace staged package")
            }
            if (!temporary.renameTo(destination)) {
                temporary.copyTo(destination, overwrite = true)
                if (!temporary.delete()) temporary.deleteOnExit()
            }
        } finally {
            if (temporary.exists() && !temporary.delete()) temporary.deleteOnExit()
        }
    }

    private fun ensureDirectory(directory: File) {
        if ((!directory.exists() && !directory.mkdirs()) || !directory.isDirectory) {
            throw IOException("Unable to create update directory")
        }
    }

    private data class ValidatedApk(
        val source: File,
        val packageName: String,
        val versionCode: Long,
        val versionName: String?,
        val sha256: String,
        val bytes: Long,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "valid" to true,
            "packageName" to packageName,
            "versionCode" to versionCode,
            "versionName" to versionName,
            "sha256" to sha256,
            "bytes" to bytes,
            "signingCompatible" to true,
        )
    }

    private data class SignerSet(
        val current: Set<String>,
        val history: Set<String>,
        val multiple: Boolean,
    )

    private class BridgeFailure(val code: String, val safeMessage: String) : Exception(safeMessage)

    companion object {
        private const val CHANNEL_NAME = "agent_atelier_r/apk_update_installer"
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private const val COPY_BUFFER_BYTES = 1024 * 1024
        private const val MIN_FREE_SPACE_BYTES = 16L * 1024L * 1024L
        private val SHA_256_PATTERN = Regex("^[0-9a-f]{64}$")
    }
}
