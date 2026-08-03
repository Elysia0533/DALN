package com.vbook.reader.loader

import android.content.Context
import eu.kanade.tachiyomi.source.Source
import com.vbook.reader.JsSource
import com.vbook.reader.engine.VBookEngine
import com.vbook.reader.model.PluginConfig
import kotlinx.serialization.json.Json
import logcat.LogPriority
import logcat.logcat
import okhttp3.OkHttpClient
import java.io.File
import java.math.BigInteger
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Handles loading of JS-based extensions (VBook style).
 */
object JsLoader {

    private val json = Json {
        ignoreUnknownKeys = true
        // Cần thiết: VBook plugin.json dùng "version": 14 (Int) nhưng model dự kiến String
        coerceInputValues = true
        isLenient = true
    }

    fun decryptScript(encStr: String, source: String, author: String): String {
        val trimmed = encStr.trim()
        if (!trimmed.contains("x0P")) return encStr

        val candidateSources = listOf(
            source,
            source.removeSuffix("/"),
            "$source/",
            "https://docln.sbs", "https://docln.net", "https://ln.hako.vn", "https://ln.hako.re",
            "http://docln.net", "http://ln.hako.vn", "docln.sbs", "docln.net", "ln.hako.vn", "hako", ""
        ).distinct()

        val candidateAuthors = listOf(
            author, "vBook", "B", "Darkrai9x", "vbook", "b", "admin", "Hako", ""
        ).distinct()

        for (s in candidateSources) {
            for (a in candidateAuthors) {
                try {
                    val cleanBase64 = trimmed
                        .replace("x0P1Xx", "+")
                        .replace("x0P2Xx", "/")
                        .replace("x0P3Xx", "=")

                    val md5Bytes = MessageDigest.getInstance("MD5").digest("com.vbook.app$s$a".toByteArray(Charsets.UTF_8))
                    val md5Passcode = md5Bytes.joinToString("") { "%02x".format(it) }
                    val aesKey = MessageDigest.getInstance("SHA-256").digest(md5Passcode.toByteArray(Charsets.UTF_8))

                    val secretKey = SecretKeySpec(aesKey, "AES")
                    val ivSpec = IvParameterSpec(ByteArray(16))

                    val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding")
                    cipher.init(Cipher.DECRYPT_MODE, secretKey, ivSpec)

                    val decodedBytes = android.util.Base64.decode(cleanBase64, android.util.Base64.DEFAULT)
                    val decryptedBytes = cipher.doFinal(decodedBytes)
                    val result = String(decryptedBytes, Charsets.UTF_8)
                    if (result.isNotBlank() && !result.contains("x0P")) {
                        return result
                    }
                } catch (_: Exception) {
                    // Try next candidate key
                }
            }
        }

        logcat(LogPriority.WARN) { "[JsLoader] Decryption failed for script, using raw" }
        return encStr
    }

    fun loadExtension(context: Context, pluginDir: File, client: OkHttpClient): JsExtensionInfo? {
        var pluginJsonFile = File(pluginDir, "plugin.json")
        var effectivePluginDir = pluginDir

        if (!pluginJsonFile.exists()) {
            val subDirs = pluginDir.listFiles { f -> f.isDirectory }
            if (subDirs != null && subDirs.size == 1) {
                val subDir = subDirs[0]
                val nestedPluginJson = File(subDir, "plugin.json")
                if (nestedPluginJson.exists()) {
                    effectivePluginDir = subDir
                    pluginJsonFile = nestedPluginJson
                }
            }
        }

        if (!pluginJsonFile.exists()) {
            logcat(LogPriority.WARN) { "plugin.json not found in ${pluginDir.absolutePath}" }
            return null
        }

        return try {
            val rawText = pluginJsonFile.readText()
            // Fix: kotlinx.serialization crashes on trailing commas. Clean them up manually.
            val configText = rawText.replace(Regex(",(?=\\s*[}\\]])"), "")
            val config = json.decodeFromString<PluginConfig>(configText)
            
            val isEncrypted = config.metadata.encrypt == true
            val srcSource = config.metadata.source ?: ""
            val srcAuthor = config.metadata.author ?: ""

            fun processContent(rawContent: String): String {
                return if (isEncrypted || rawContent.contains("x0P")) {
                    decryptScript(rawContent, srcSource, srcAuthor)
                } else {
                    rawContent
                }
            }
            
            val scripts = mutableMapOf<String, String>()
            val srcDir = File(effectivePluginDir, "src")
            
            // Load all JS files in effectivePluginDir and srcDir to make them available for dynamic execution
            effectivePluginDir.listFiles { file -> file.extension == "js" }?.forEach { file ->
                scripts[file.nameWithoutExtension] = processContent(file.readText())
            }
            if (srcDir.exists() && srcDir.isDirectory) {
                srcDir.listFiles { file -> file.extension == "js" }?.forEach { file ->
                    scripts[file.nameWithoutExtension] = processContent(file.readText())
                }
            }
            
            // Also load explicitly defined scripts in root just in case
            fun readScript(name: String?, key: String) {
                if (name == null) return
                val canonicalRootDir = effectivePluginDir.canonicalFile
                val rootFile = File(effectivePluginDir, name).canonicalFile
                if (rootFile.exists() && rootFile.path.startsWith(canonicalRootDir.path) && !scripts.containsKey(key)) {
                    scripts[key] = processContent(rootFile.readText())
                } else if (!scripts.containsKey(key)) {
                    val srcFile = File(srcDir, name).canonicalFile
                    if (srcFile.exists() && srcFile.path.startsWith(canonicalRootDir.path)) scripts[key] = processContent(srcFile.readText())
                }
            }

            readScript(config.script.home, "home")
            readScript(config.script.genre, "genre")
            readScript(config.script.detail, "detail")
            readScript(config.script.search, "search")
            readScript(config.script.page, "page")
            readScript(config.script.toc, "toc")
            readScript(config.script.chap, "chap")

            // Kiểm tra các script bắt buộc: toc + chap
            val mandatoryScripts = listOf("toc", "chap")
            val missingScripts = mandatoryScripts.filter { !scripts.containsKey(it) }
            if (missingScripts.isNotEmpty()) {
                logcat(LogPriority.WARN) {
                    "[JsLoader] ${pluginDir.name}: Thiếu script bắt buộc: $missingScripts. " +
                    "Plugin có thể tải được nhưng không đọc truyện được."
                }
            }

            fun normalizeLang(code: String?): String {
                if (code.isNullOrBlank()) return "all"
                val normalized = code.trim().lowercase()
                return when {
                    normalized == "global" -> "all"
                    normalized.contains("_") -> normalized.substringBefore("_")
                    normalized.contains("-") -> normalized.substringBefore("-")
                    else -> normalized
                }
            }

            // Ưu tiên locale, fallback language, cuối cùng là all.
            val lang = normalizeLang(config.metadata.locale ?: config.metadata.language)

            // Fix: ID phải khớp với ExtensionApi.sourceId formula
            // Dùng cùng offset 0x5642000000000000L ("VB" in hex) và cùng input hash
            val sourceId = 0x5642000000000000L or
                ((config.metadata.name + lang).hashCode().toLong() and 0xFFFFFFFFL)

            val sourceUrl = config.metadata.source ?: ""
            val engine = VBookEngine(client, effectivePluginDir, baseUrl = sourceUrl)

            val source = JsSource(
                id = sourceId,
                name = config.metadata.name,
                lang = lang,
                engine = engine,
                scripts = scripts,
                baseUrl = sourceUrl,
                isNovel = config.metadata.type == "novel"
            )

            val iconFile = File(effectivePluginDir, "icon.png")
            val iconDrawable = if (iconFile.exists()) {
                android.graphics.drawable.BitmapDrawable(context.resources, android.graphics.BitmapFactory.decodeFile(iconFile.absolutePath))
            } else null

            JsExtensionInfo(
                source = source,
                versionName = config.metadata.resolvedVersionName(),
                versionCode = config.metadata.resolvedVersionCode(),
                isNsfw = config.metadata.tag?.lowercase()?.let {
                    it.contains("18+") || it.contains("nsfw")
                } == true,
                author = config.metadata.author,
                isNovel = config.metadata.type == "novel",
                icon = iconDrawable
            )
        } catch (e: Throwable) {
            logcat(LogPriority.ERROR) { "Failed to load JS extension from ${pluginDir.absolutePath}: ${e.message}\n${e.stackTraceToString()}" }
            try {
                java.io.File(context.cacheDir, "js_error_${pluginDir.name}.txt").writeText("Error: ${e.message}\n${e.stackTraceToString()}")
            } catch (ex: Exception) {}
            null
        }
    }
}

data class JsExtensionInfo(
    val source: Source,
    val versionName: String,
    val versionCode: Long,
    val isNsfw: Boolean,
    val author: String?,
    val isNovel: Boolean = true,  // VBook default là novel; comic type sẽ false
    val icon: android.graphics.drawable.Drawable? = null
)
