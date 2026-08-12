package com.vbook.reader

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import com.vbook.reader.loader.JsLoader
import java.io.File
import logcat.LogPriority
import logcat.logcat

class MainActivity : FlutterActivity() {
    private val COOKIE_CHANNEL = "com.vbook.reader/cookie_manager"
    private val ENGINE_CHANNEL = "com.vbook.reader/vbook_engine"
    
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .callTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .cookieJar(WebViewCookieJar())
        .build()
    // Key: pluginId (String from Dart), Value: JsSource
    private val sources = mutableMapOf<String, JsSource>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
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
                    
                    sources.remove(id)?.closeEngine()
                    
                    CoroutineScope(Dispatchers.IO).launch {
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
                            sources[id] = jsSource
                            
                            logcat(LogPriority.INFO) { "[MainActivity] loadSource: loaded '${jsSource.name}' (engineId=$id, sourceId=${jsSource.id})" }
                            
                            withContext(Dispatchers.Main) { result.success(true) }
                        } catch (e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] loadSource exception: ${e.message}\n${e.stackTraceToString()}" }
                            withContext(Dispatchers.Main) { result.error("LOAD_ERROR", "${e.message}\n${e.stackTraceToString()}", null) }
                        }
                    }
                }
                "getPopularManga" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val page = call.argument<Int>("page") ?: 1
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded. Call loadSource first.", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val mangasPage = source.getPopularManga(page)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            withContext(Dispatchers.Main) { result.success(res) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getPopularManga error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "getLatestUpdates" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val page = call.argument<Int>("page") ?: 1
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded. Call loadSource first.", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val mangasPage = source.getLatestUpdates(page)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            withContext(Dispatchers.Main) { result.success(res) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getLatestUpdates error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "getSearchManga" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val page = call.argument<Int>("page") ?: 1
                    val query = call.argument<String>("query") ?: ""
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val filters = eu.kanade.tachiyomi.source.model.FilterList()
                            val mangasPage = source.getSearchManga(page, query, filters)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            withContext(Dispatchers.Main) { result.success(res) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getSearchManga error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "getHomeTabs" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val tabs = source.getHomeTabs()
                            withContext(Dispatchers.Main) { result.success(tabs) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getHomeTabs error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "getMangaListByTab" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val input = call.argument<String>("input") ?: ""
                    val script = call.argument<String>("script") ?: "gen.js"
                    val page = call.argument<Int>("page") ?: 1
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val mangasPage = source.getMangaListByTab(input, script, page)
                            val jsonList = mangasPage.mangas.map { m ->
                                mapOf("url" to m.url, "title" to m.title, "thumbnail_url" to m.thumbnail_url, "description" to m.description)
                            }
                            val res = mapOf("mangas" to jsonList, "hasNextPage" to mangasPage.hasNextPage)
                            withContext(Dispatchers.Main) { result.success(res) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getMangaListByTab error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "getMangaDetails" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val url = call.argument<String>("url") ?: ""
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
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
                            withContext(Dispatchers.Main) { result.success(res) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getMangaDetails error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "getChapterList" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val url = call.argument<String>("url") ?: ""
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val manga = eu.kanade.tachiyomi.source.model.SManga.create().apply { this.url = url }
                            val chapters = source.getChapterList(manga)
                            val jsonList = chapters.map { c ->
                                mapOf("url" to c.url, "name" to c.name, "date_upload" to c.date_upload)
                            }
                            withContext(Dispatchers.Main) { result.success(jsonList) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getChapterList error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "getPageList" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val url = call.argument<String>("url") ?: ""
                    val source = sources[id] ?: return@setMethodCallHandler result.error("NOT_LOADED", "Source '$id' not loaded", null)
                    
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val chapter = eu.kanade.tachiyomi.source.model.SChapter.create().apply { this.url = url }
                            val pages = source.getPageList(chapter)
                            val jsonList = pages.map { p ->
                                mapOf("index" to p.index, "url" to p.url, "imageUrl" to p.imageUrl)
                            }
                            withContext(Dispatchers.Main) { result.success(jsonList) }
                        } catch(e: Exception) {
                            logcat(LogPriority.ERROR) { "[MainActivity] getPageList error: ${e.message}" }
                            withContext(Dispatchers.Main) { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "closeSource" -> {
                    val id = call.argument<String>("id") ?: return@setMethodCallHandler result.error("INVALID_ID", "Plugin ID is null", null)
                    val source = sources.remove(id)
                    source?.closeEngine()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
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
