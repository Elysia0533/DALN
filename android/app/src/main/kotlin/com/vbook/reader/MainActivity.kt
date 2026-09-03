package com.vbook.reader

import android.content.pm.PackageManager
import android.os.Build
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import com.vbook.reader.engine.VBookEngineException
import com.vbook.reader.loader.JsLoader
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import logcat.LogPriority
import logcat.logcat

class MainActivity : FlutterActivity() {
    private val COOKIE_CHANNEL = "com.vbook.reader/cookie_manager"
    private val ENGINE_CHANNEL = "com.vbook.reader/vbook_engine"
    private val APP_IDENTITY_CHANNEL = "com.vbook.reader/app_identity"
    
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .callTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .cookieJar(WebViewCookieJar())
        .build()
    private val engineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sourceGenerations = ConcurrentHashMap<String, AtomicLong>()
    private val sources = ConcurrentHashMap<String, LoadedSource>()

    private data class LoadedSource(
        val generation: Long,
        val source: JsSource,
    )

    private fun nextSourceGeneration(id: String): Long =
        sourceGenerations.computeIfAbsent(id) { AtomicLong(0L) }.incrementAndGet()

    private fun currentSourceGeneration(id: String): Long =
        sourceGenerations[id]?.get() ?: 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_IDENTITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getGoogleDriveApiKey" -> {
                    result.success(getString(R.string.vbook_google_drive_api_key).trim())
                }
                "getGoogleApiKeyRestrictionHeaders" -> {
                    val certSha1 = signingCertificateSha1Hex()
                    if (certSha1 == null) {
                        result.error("CERT_UNAVAILABLE", "Android signing certificate is unavailable.", null)
                    } else {
                        result.success(
                            mapOf(
                                "X-Android-Package" to packageName,
                                "X-Android-Cert" to certSha1
                            )
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COOKIE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getCookies") {
                val url = call.argument<String>("url")
                if (url != null) {
                    val cookies = CookieManager.getInstance().getCookie(url)
                    result.success(cookies ?: "")
                } else {
                    result.error("INVALID_URL", "URL is null", null)
                }
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENGINE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "loadSource" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val dirPath = call.argument<String>("dirPath") ?: return@setMethodCallHandler result.error("INVALID_DIR", "Directory path is null", null)

                    val generation = nextSourceGeneration(id)
                    sources.remove(id)?.source?.closeEngine()

                    engineScope.launch {
                        try {
                            val dir = File(dirPath)
                            if (!dir.exists()) {
                                logcat(LogPriority.ERROR) { "[MainActivity] loadSource: dir not found: $dirPath" }
                                withContext(Dispatchers.Main) { result.error("DIR_NOT_FOUND", "Directory not found: $dirPath", null) }
                                return@launch
                            }
                            
                            // ── Diagnostic: list all files in the plugin directory ──
                            logcat(LogPriority.INFO) { "[MainActivity] loadSource: loading from $dirPath with id=$id" }

                            // Use the proper JsLoader which handles plugin.json, nested dirs, script loading
                            val extensionInfo = JsLoader.loadExtension(this@MainActivity, dir, client)
                            if (extensionInfo == null) {
                                // Read cached error file if JsLoader wrote one
                                val errorFile = File(this@MainActivity.cacheDir, "js_error_${dir.name}.txt")
                                val errorDetail = if (errorFile.exists()) errorFile.readText() else "JsLoader returned null (no error file found)"
                                logcat(LogPriority.ERROR) { "[MainActivity] loadSource: LOAD_FAILED for $dirPath\n$errorDetail" }
                                withContext(Dispatchers.Main) { result.error("LOAD_FAILED", "Failed to load extension '$id' from $dirPath: $errorDetail", null) }
                                return@launch
                            }
                            
                            val jsSource = extensionInfo.source as JsSource
                            if (currentSourceGeneration(id) != generation) {
                                jsSource.closeEngine()
                                withContext(Dispatchers.Main) {
                                    result.error(
                                        "EXEC_CANCELLED",
                                        "Extension load was cancelled because its source session changed.",
                                        null,
                                    )
                                }
                                return@launch
                            }
                            val loadedSource = LoadedSource(generation, jsSource)
                            sources.put(id, loadedSource)?.source?.closeEngine()
                            
                            logcat(LogPriority.INFO) { "[MainActivity] loadSource: loaded '${jsSource.name}' (engineId=$id, sourceId=${jsSource.id})" }
                            
                            withContext(Dispatchers.Main) { result.success(true) }
                        } catch (e: Exception) {
                            if (currentSourceGeneration(id) != generation) {
                                withContext(Dispatchers.Main) {
                                    result.error(
                                        "EXEC_CANCELLED",
                                        "Extension load was cancelled because its source session changed.",
                                        null,
                                    )
                                }
                            } else {
                                logcat(LogPriority.ERROR) { "[MainActivity] loadSource failed: ${e::class.simpleName}" }
                                withContext(Dispatchers.Main) {
                                    result.error("LOAD_ERROR", "Extension source could not be loaded.", null)
                                }
                            }
                        }
                    }
                }
                "getPopularManga" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val page = call.argument<Int>("page") ?: 1
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded. Call loadSource first.", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val mangasPage = source.getPopularManga(page)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            completeEngineCall(id, sourceSession, result, res)
                        } catch(e: Exception) {
                            completeEngineFailure("getPopularManga", id, sourceSession, result, e)
                        }
                    }
                }
                "getLatestUpdates" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val page = call.argument<Int>("page") ?: 1
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded. Call loadSource first.", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val mangasPage = source.getLatestUpdates(page)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            completeEngineCall(id, sourceSession, result, res)
                        } catch(e: Exception) {
                            completeEngineFailure("getLatestUpdates", id, sourceSession, result, e)
                        }
                    }
                }
                "getSearchManga" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val page = call.argument<Int>("page") ?: 1
                    val query = call.argument<String>("query") ?: ""
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val filters = eu.kanade.tachiyomi.source.model.FilterList()
                            val mangasPage = source.getSearchManga(page, query, filters)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            completeEngineCall(id, sourceSession, result, res)
                        } catch(e: Exception) {
                            completeEngineFailure("getSearchManga", id, sourceSession, result, e)
                        }
                    }
                }
                "getHomeTabs" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val tabs = source.getHomeTabs()
                            completeEngineCall(id, sourceSession, result, tabs)
                        } catch(e: Exception) {
                            completeEngineFailure("getHomeTabs", id, sourceSession, result, e)
                        }
                    }
                }
                "getMangaListByTab" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val input = call.argument<String>("input") ?: ""
                    val script = call.argument<String>("script") ?: "gen.js"
                    val page = call.argument<Int>("page") ?: 1
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val mangasPage = source.getMangaListByTab(input, script, page)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            completeEngineCall(id, sourceSession, result, res)
                        } catch(e: Exception) {
                            completeEngineFailure("getMangaListByTab", id, sourceSession, result, e)
                        }
                    }
                }
                "getMangaDetails" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val url = call.argument<String>("url") ?: ""
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val manga = eu.kanade.tachiyomi.source.model.SManga.create().apply { this.url = url }
                            val details = source.getMangaDetails(manga)
                            val res = mapOf(
                                "title" to details.title,
                                "author" to details.author,
                                "artist" to details.artist,
                                "description" to details.description,
                                "genre" to details.genre,
                                "status" to details.status,
                                "thumbnail_url" to details.thumbnail_url
                            )
                            completeEngineCall(id, sourceSession, result, res)
                        } catch(e: Exception) {
                            completeEngineFailure("getMangaDetails", id, sourceSession, result, e)
                        }
                    }
                }
                "getChapterList" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val url = call.argument<String>("url") ?: ""
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val manga = eu.kanade.tachiyomi.source.model.SManga.create().apply { this.url = url }
                            val chapters = source.getChapterList(manga)
                            val jsonList = chapters.map { c ->
                                mapOf("url" to c.url, "name" to c.name, "date_upload" to c.date_upload)
                            }
                            completeEngineCall(id, sourceSession, result, jsonList)
                        } catch(e: Exception) {
                            completeEngineFailure("getChapterList", id, sourceSession, result, e)
                        }
                    }
                }
                "getPageList" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val url = call.argument<String>("url") ?: ""
                    val sourceSession = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    val source = sourceSession.source
                    
                    engineScope.launch {
                        try {
                            val chapter = eu.kanade.tachiyomi.source.model.SChapter.create().apply { this.url = url }
                            val pages = source.getPageList(chapter)
                            val jsonList = pages.map { p ->
                                mapOf("index" to p.index, "url" to p.url, "imageUrl" to p.imageUrl)
                            }
                            completeEngineCall(id, sourceSession, result, jsonList)
                        } catch(e: Exception) {
                            completeEngineFailure("getPageList", id, sourceSession, result, e)
                        }
                    }
                }
                "closeSource" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    nextSourceGeneration(id)
                    val source = sources.remove(id)
                    source?.source?.closeEngine()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        sourceGenerations.values.forEach { it.incrementAndGet() }
        sources.values.forEach { it.source.closeEngine() }
        sources.clear()
        engineScope.cancel()
        super.onDestroy()
    }

    private suspend fun completeEngineCall(
        id: String,
        sourceSession: LoadedSource,
        result: MethodChannel.Result,
        value: Any?,
    ) {
        withContext(Dispatchers.Main) {
            if (sources[id] !== sourceSession) {
                result.error(
                    "EXEC_CANCELLED",
                    "Extension execution was cancelled because its source session changed.",
                    null,
                )
            } else {
                result.success(value)
            }
        }
    }

    private suspend fun completeEngineFailure(
        operation: String,
        id: String,
        sourceSession: LoadedSource,
        result: MethodChannel.Result,
        error: Exception,
    ) {
        val engineError = error as? VBookEngineException
        val code = engineError?.platformCode ?: "JS_ERROR"
        val message = engineError?.message ?: "Extension JavaScript failed while running '$operation'."
        logcat(LogPriority.ERROR) { "[MainActivity] $operation failed with code=$code" }

        withContext(Dispatchers.Main) {
            if (sources[id] !== sourceSession) {
                result.error(
                    "EXEC_CANCELLED",
                    "Extension execution was cancelled because its source session changed.",
                    null,
                )
            } else {
                result.error(code, message, null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun signingCertificateSha1Hex(): String? {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val packageInfo = packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES
            )
            val signingInfo = packageInfo.signingInfo ?: return null
            val signerArray = if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
            signerArray ?: return null
        } else {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNATURES
            ).signatures ?: return null
        }
        val signature = signatures.firstOrNull() ?: return null
        val digest = MessageDigest.getInstance("SHA-1").digest(signature.toByteArray())
        return digest.joinToString(separator = "") { byte -> "%02X".format(byte) }
    }
}

class WebViewCookieJar : CookieJar {
    private val cookieManager = CookieManager.getInstance()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val urlString = url.toString()
        for (cookie in cookies) {
            cookieManager.setCookie(urlString, cookie.toString())
            if (urlString.contains("docln.sbs")) {
                cookieManager.setCookie("https://ln.hako.vn/", cookie.toString())
                cookieManager.setCookie("https://ln.hako.re/", cookie.toString())
            }
        }
        cookieManager.flush()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val urlString = url.toString()
        var cookieString = cookieManager.getCookie(urlString)
        
        if (cookieString.isNullOrEmpty() && (urlString.contains("hako") || urlString.contains("docln"))) {
            cookieString = cookieManager.getCookie("https://docln.sbs/")
                ?: cookieManager.getCookie("https://ln.hako.vn/")
        }

        if (cookieString.isNullOrEmpty()) return emptyList()

        return cookieString.split(";").mapNotNull {
            try {
                Cookie.parse(url, it.trim())
            } catch (_: Exception) {
                null
            }
        }
    }
}
