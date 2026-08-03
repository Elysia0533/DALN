package com.vbook.reader

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import com.vbook.reader.engine.VBookEngine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import logcat.LogPriority
import logcat.logcat
import org.jsoup.Jsoup
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Dispatchers

/**
 * A Source implementation that delegates to a VBook JS script.
 * Hỗ trợ 3 loại extension:
 *   - comic: truyện tranh (chỉ có ảnh)
 *   - novel: truyện chữ (chỉ có text/HTML)
 *   - light novel: có cả text lẫn ảnh minh họa (trả về HTML có <img> + <p>)
 */
class JsSource(
    override val id: Long,
    override val name: String,
    override val lang: String,
    private val engine: VBookEngine,
    private val scripts: Map<String, String>,
    val baseUrl: String = "",
    val isNovel: Boolean = false
) : CatalogueSource {

    override val supportsLatest: Boolean = scripts.containsKey("home")

    private val json = Json { ignoreUnknownKeys = true }

    val headers: okhttp3.Headers = okhttp3.Headers.Builder()
        .add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .build()

    fun closeEngine() {
        try { engine.close() } catch (_: Exception) {}
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /** Parse một JsonElement? thành List<JsonElement> nếu nó là array, không thì trả emptyList */
    private fun kotlinx.serialization.json.JsonElement?.asJsonArray(): List<kotlinx.serialization.json.JsonElement> =
        if (this is JsonArray) this.toList() else emptyList()

    /** Lấy content của JsonPrimitive, trả null nếu không phải primitive */
    private fun kotlinx.serialization.json.JsonElement?.stringValue(): String? =
        (this as? JsonPrimitive)?.takeIf { it.isString || it.content.isNotEmpty() }?.content

    /** Strip HTML tags, convert <br>/<p> thành newline để hiển thị clean */
    private fun stripHtml(html: String): String {
        if (!html.contains('<')) return html.trim()
        return try {
            Jsoup.parse(html).text().trim()
        } catch (e: Exception) {
            html.replace(Regex("<[^>]+>"), "").trim()
        }
    }

    /**
     * Extract image URL từ một JsonElement trong array chap.js.
     * Các extensions dùng các field khác nhau:
     *   - TruyenQQ comic: { link: "thumbnail_url", fallback: ["real_url"] }
     *   - Hako novel: data là string HTML (không phải array ảnh)
     *   - Generic: string trực tiếp, hoặc { url/src/image: "..." }
     *
     * Ưu tiên: fallback[0] > link > url > src > image > data-original
     */
    private fun extractImageUrlFromElement(element: kotlinx.serialization.json.JsonElement): String {
        return when (element) {
            is JsonPrimitive -> element.content.takeIf { it.isNotBlank() } ?: ""
            is JsonObject -> {
                // Ưu tiên fallback[0] (TruyenQQ dùng field này cho real URL)
                val fallback = element["fallback"] as? JsonArray
                val fallbackUrl = fallback?.firstOrNull()?.let {
                    (it as? JsonPrimitive)?.content?.takeIf { url -> url.isNotBlank() }
                }
                if (!fallbackUrl.isNullOrBlank()) return fallbackUrl

                // Thứ tự ưu tiên field tên ảnh
                for (key in listOf("url", "src", "image", "link", "data-original", "path", "img", "imageUrl")) {
                    val v = element[key]?.stringValue()
                    if (!v.isNullOrBlank()) return v
                }
                ""
            }
            else -> ""
        }
    }

    /**
     * Xác định xem một URL có phải là URL ảnh hợp lệ không.
     * Dùng để phân biệt array ảnh vs array dữ liệu khác.
     */
    private fun looksLikeImageUrl(url: String): Boolean {
        if (url.isBlank()) return false
        val lower = url.lowercase()
        if (!lower.startsWith("http")) return false
        return lower.contains(Regex("\\.(jpg|jpeg|png|gif|webp|avif|bmp)(\\?.*)?$"))
            || lower.contains("/images/")
            || lower.contains("/img/")
            || lower.contains("/cdn/")
            || lower.contains("/uploads/")
            || lower.contains("/chapters/")
            || lower.contains("/manga/")
            || lower.contains("cdn")
            || lower.contains("image")
    }

    /** Build một manga object từ JsonObject trả về từ gen.js/search.js */
    private fun buildMangaFromJson(o: JsonObject): SManga {
        return SManga.create().apply {
            val rawUrl = o["link"]?.stringValue() ?: o["url"]?.stringValue() ?: ""
            val host = o["host"]?.stringValue()?.ifBlank { null } ?: baseUrl
            url = when {
                rawUrl.startsWith("http") -> rawUrl
                rawUrl.startsWith("/") && host.isNotBlank() -> host.trimEnd('/') + rawUrl
                else -> rawUrl
            }
            title = o["name"]?.stringValue() ?: o["title"]?.stringValue() ?: ""

            // Extract description / chapter / subTitle / latest info
            val desc = o["description"]?.stringValue()
                ?: o["subTitle"]?.stringValue()
                ?: o["chap"]?.stringValue()
                ?: o["chapter"]?.stringValue()
                ?: o["latest"]?.stringValue()
                ?: o["new_chapter"]?.stringValue()
                ?: o["author"]?.stringValue()
                ?: ""
            description = stripHtml(desc)

            // Cover URL: thử cover trước, rồi img, rồi thumbnail, rồi data-bg
            var cover = o["cover"]?.stringValue() ?: ""
            if (cover.isBlank()) cover = o["img"]?.stringValue() ?: ""
            if (cover.isBlank()) cover = o["thumbnail"]?.stringValue() ?: ""
            if (cover.isBlank()) cover = o["data-bg"]?.stringValue() ?: ""
            if (cover.isBlank()) cover = o["data-src"]?.stringValue() ?: ""
            if (cover.startsWith("//")) cover = "https:$cover"
            if (cover.startsWith("/") && host.isNotBlank()) cover = host.trimEnd('/') + cover
            thumbnail_url = cover
        }
    }

    // ─── getMangaDetails ─────────────────────────────────────────────────────

    override suspend fun getMangaDetails(manga: SManga): SManga {
        val script = scripts["detail"] ?: return manga
        val result = engine.execute(script, "execute", manga.url) ?: return manga

        return try {
            val jsonResult = json.parseToJsonElement(result).jsonObject
            val data = jsonResult["data"]?.jsonObject ?: return manga

            manga.apply {
                val parsedAuthor = data["author"]?.stringValue()
                if (!parsedAuthor.isNullOrBlank()) author = parsedAuthor
                
                val parsedArtist = data["artist"]?.stringValue()
                if (!parsedArtist.isNullOrBlank()) artist = parsedArtist
                else if (artist.isNullOrBlank() && !parsedAuthor.isNullOrBlank()) artist = parsedAuthor

                // description thường là HTML (ví dụ: "<p>...</p>") → phải strip
                val rawDesc = data["description"]?.stringValue()
                if (!rawDesc.isNullOrBlank()) description = stripHtml(rawDesc)

                // Cover URL từ detail.js
                val rawCover = data["cover"]?.stringValue() ?: ""
                val host = data["host"]?.stringValue()?.ifBlank { null } ?: baseUrl
                if (rawCover.isNotBlank()) {
                    thumbnail_url = when {
                        rawCover.startsWith("//") -> "https:$rawCover"
                        rawCover.startsWith("/") && host.isNotBlank() -> host.trimEnd('/') + rawCover
                        else -> rawCover
                    }
                }

                // Genres: có thể là array [{title, input, script}] hoặc string
                val genresArray = data["genres"]?.asJsonArray()
                val tagsStr = if (genresArray != null && genresArray.isNotEmpty()) {
                    genresArray.mapNotNull {
                        when (it) {
                            is JsonObject -> it["title"]?.stringValue()
                            is JsonPrimitive -> if (it.isString) it.content else null
                            else -> null
                        }
                    }.joinToString(", ")
                } else {
                    data["tag"]?.stringValue()
                }
                if (!tagsStr.isNullOrBlank()) genre = tagsStr

                // Status
                val ongoing = data["ongoing"]?.let {
                    (it as? JsonPrimitive)?.content?.lowercase()
                }
                val statusStr = data["status"]?.stringValue()?.lowercase()
                status = when {
                    ongoing == "true" -> SManga.ONGOING
                    ongoing == "false" -> SManga.COMPLETED
                    statusStr == "ongoing" -> SManga.ONGOING
                    statusStr == "completed" -> SManga.COMPLETED
                    else -> SManga.UNKNOWN
                }
            }
        } catch (e: Exception) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] getMangaDetails error: ${e.message}" }
            manga
        }
    }

    // ─── getChapterList ───────────────────────────────────────────────────────

    override suspend fun getChapterList(manga: SManga): List<SChapter> {
        val script = scripts["toc"] ?: return emptyList()
        val result = engine.execute(script, "execute", manga.url) ?: return emptyList()

        return try {
            val jsonResult = json.parseToJsonElement(result).jsonObject
            val chaptersJson = jsonResult["data"]?.asJsonArray() ?: return emptyList()

            chaptersJson.mapNotNull { el ->
                val o = el as? JsonObject ?: return@mapNotNull null
                val chapUrl = o["url"]?.stringValue() ?: return@mapNotNull null
                val host = o["host"]?.stringValue()?.ifBlank { null } ?: baseUrl
                SChapter.create().apply {
                    url = when {
                        chapUrl.startsWith("http") -> chapUrl
                        chapUrl.startsWith("/") && host.isNotBlank() -> host.trimEnd('/') + chapUrl
                        else -> chapUrl
                    }
                    name = o["name"]?.stringValue() ?: ""
                    date_upload = o["date"]?.jsonPrimitive?.longOrNull ?: 0L
                }
            }
        } catch (e: Exception) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] getChapterList error: ${e.message}" }
            emptyList()
        }
    }

    // ─── getPageList ──────────────────────────────────────────────────────────

    /**
     * Resolve trang qua sub-script (pattern {link, script} dùng bởi e-hentai, cuutruyen).
     * Một số extension dùng 2 bước:
     *   Step 1) chap.js → [{link: "viewer_page_url", script: "img.js"}, ...]
     *   Step 2) img.js  → fetch viewer_page_url → extract real image URL
     *
     * Trả về null nếu không resolve được.
     */
    private suspend fun resolveScriptPage(pageViewerUrl: String, scriptName: String): String? {
        val key = scriptName.substringBeforeLast(".")
        val subScript = scripts[key] ?: run {
            logcat(LogPriority.WARN) { "[JsSource:$name] sub-script '$key' not found" }
            return null
        }
        val result = engine.execute(subScript, "execute", pageViewerUrl) ?: return null

        // Sub-script có thể trả về:
        //  (a) JSON format: {"data": "https://...", ...}
        //  (b) Plain URL string: "https://..."
        //  (c) null / empty → failed
        val trimmed = result.trim()
        if (trimmed.isBlank() || trimmed == "null") return null

        // Thử parse JSON trước
        return try {
            val jsonResult = json.parseToJsonElement(trimmed)
            when {
                jsonResult is kotlinx.serialization.json.JsonObject -> {
                    // {"data": "url"} hoặc {"data": {"url": "..."} }
                    val dataEl = jsonResult["data"]
                    dataEl?.stringValue()
                        ?: (dataEl as? kotlinx.serialization.json.JsonObject)?.let {
                            it["url"]?.stringValue() ?: it["src"]?.stringValue()
                        }
                }
                jsonResult is kotlinx.serialization.json.JsonPrimitive -> jsonResult.content.takeIf { it.isNotBlank() }
                else -> null
            }
        } catch (_: Exception) {
            // Không phải JSON → treat as raw URL
            if (trimmed.startsWith("http")) trimmed else null
        }
    }

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val script = scripts["chap"] ?: run {
            logcat(LogPriority.WARN) { "[JsSource:$name] Không có script 'chap'" }
            return emptyList()
        }
        val result = engine.execute(script, "execute", chapter.url)
        if (result == null) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] execute() trả null cho chapter: ${chapter.url}" }
            return emptyList()
        }

        logcat(LogPriority.DEBUG) { "[JsSource:$name] getPageList raw (${result.length} chars): ${result.take(800)}" }

        return try {
            val jsonResult = json.parseToJsonElement(result).jsonObject
            val dataElement = jsonResult["data"] ?: run {
                logcat(LogPriority.WARN) { "[JsSource:$name] Không có field 'data'. Keys: ${jsonResult.keys}" }
                return emptyList()
            }

            when {
                // ── Case A: data là JsonArray ─────────────────────────────────
                // VD: blogtruyen/mangadex → ["url1", "url2"] (plain string array)
                // VD: nettruyen/truyenqq  → [{link:"url", fallback:["url2"]}]
                // VD: e-hentai/cuutruyen  → [{link:"viewer_url", script:"img.js"}] (2-step)
                dataElement is JsonArray -> {
                    logcat(LogPriority.DEBUG) { "[JsSource:$name] data is array, size=${dataElement.size}" }
                    if (dataElement.isEmpty()) return emptyList()

                    // Kiểm tra xem array có dùng pattern {link, script} không
                    val firstObj = dataElement.firstOrNull() as? JsonObject
                    val hasScriptPattern = firstObj?.containsKey("script") == true
                        && firstObj.containsKey("link")

                    if (hasScriptPattern) {
                        // Two-step pattern: resolve từng page qua sub-script (parallel)
                        logcat(LogPriority.DEBUG) { "[JsSource:$name] Detected {link, script} pattern — resolving ${dataElement.size} pages in parallel" }
                        val deferreds = dataElement.mapIndexedNotNull { index, element ->
                            val obj = element as? JsonObject ?: return@mapIndexedNotNull null
                            val pageViewerUrl = obj["link"]?.stringValue() ?: return@mapIndexedNotNull null
                            val scriptName = obj["script"]?.stringValue() ?: return@mapIndexedNotNull null
                            Pair(index, Pair(pageViewerUrl, scriptName))
                        }
                        val pages = coroutineScope {
                            val jobs = deferreds.map { item ->
                                val index = item.first
                                val pageViewerUrl = item.second.first
                                val scriptName = item.second.second
                                async(Dispatchers.IO) {
                                    val resolvedUrl = resolveScriptPage(pageViewerUrl, scriptName)
                                    if (resolvedUrl != null) Page(index, chapter.url, resolvedUrl) else null
                                }
                            }
                            jobs.mapNotNull { it.await() }
                        }
                        logcat(LogPriority.DEBUG) { "[JsSource:$name] Resolved ${pages.size}/${dataElement.size} pages via sub-script" }
                        return pages
                    }

                    // Normal array: extract URL trực tiếp
                    val pages = dataElement.mapIndexedNotNull { index, element ->
                        val url = extractImageUrlFromElement(element)
                        if (url.isNotBlank()) Page(index, chapter.url, url) else null
                    }

                    if (pages.isNotEmpty()) {
                        logcat(LogPriority.DEBUG) { "[JsSource:$name] Parsed ${pages.size} image pages from array" }
                        return pages
                    }
                    emptyList()
                }

                // ── Case B: data là JsonPrimitive (string) ────────────────────
                // VD: Hako chap.js → trả về string HTML trực tiếp
                // Có thể là: plain text, HTML text, HTML có <img> (light novel)
                dataElement is JsonPrimitive && dataElement.isString -> {
                    val content = dataElement.content
                    logcat(LogPriority.DEBUG) { "[JsSource:$name] data is string len=${content.length}" }
                    if (content.isBlank()) return emptyList()
                    listOf(Page(0, chapter.url, "vbook-text://$content"))
                }

                // ── Case C: data là JsonObject ────────────────────────────────
                // Một số extension wrap data trong object
                dataElement is JsonObject -> {
                    logcat(LogPriority.DEBUG) { "[JsSource:$name] data is object, keys=${dataElement.keys}" }

                    // C1: Tìm các field chứa mảng ảnh (pages, images, imgs...)
                    val imageArrayKeys = listOf("pages", "images", "imgs", "imageList", "listImages", "chapter_images", "data", "list")
                    for (key in imageArrayKeys) {
                        val arr = dataElement[key] as? JsonArray ?: continue
                        if (arr.isEmpty()) continue

                        val pages = arr.mapIndexedNotNull { index, el ->
                            val url = extractImageUrlFromElement(el)
                            if (url.isNotBlank()) Page(index, chapter.url, url) else null
                        }
                        if (pages.isNotEmpty()) {
                            logcat(LogPriority.DEBUG) { "[JsSource:$name] Found ${pages.size} images in field '$key'" }
                            return pages
                        }
                    }

                    // C2: Tìm field text/html chứa nội dung truyện chữ
                    val textKeys = listOf("content", "text", "html", "body", "chapterText", "chapter_content")
                    for (key in textKeys) {
                        val text = dataElement[key]?.stringValue()
                        if (!text.isNullOrBlank()) {
                            logcat(LogPriority.DEBUG) { "[JsSource:$name] Found text in field '$key', len=${text.length}" }
                            return listOf(Page(0, chapter.url, "vbook-text://$text"))
                        }
                    }

                    // C3: Fallback - tìm string dài nhất trong object (> 100 chars)
                    val longestText = dataElement.entries
                        .mapNotNull { (k, v) ->
                            val s = v.stringValue()
                            if (!s.isNullOrBlank() && s.length > 100) Pair(k, s) else null
                        }
                        .maxByOrNull { it.second.length }

                    if (longestText != null) {
                        logcat(LogPriority.DEBUG) { "[JsSource:$name] Fallback: using field '${longestText.first}' as text" }
                        return listOf(Page(0, chapter.url, "vbook-text://${longestText.second}"))
                    }

                    logcat(LogPriority.WARN) { "[JsSource:$name] data object không nhận ra format. Keys: ${dataElement.keys}" }
                    emptyList()
                }

                else -> {
                    logcat(LogPriority.WARN) { "[JsSource:$name] data type không xử lý được: ${dataElement::class.simpleName}" }
                    emptyList()
                }
            }
        } catch (e: Exception) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] getPageList exception: ${e.message}\nResult: ${result.take(500)}" }
            emptyList()
        }
    }

    // ─── getPopularManga ──────────────────────────────────────────────────────

    override suspend fun getPopularManga(page: Int): MangasPage {
        return fetchMangaListFromHome(page, isLatest = false)
    }

    override suspend fun getLatestUpdates(page: Int): MangasPage {
        // Thử dùng script "latest" riêng nếu extension có
        val latestScript = scripts["latest"]
        if (latestScript != null) {
            return try {
                val result = engine.execute(latestScript, "execute", page.toString())
                    ?: return MangasPage(emptyList(), false)
                val jsonResult = json.parseToJsonElement(result).jsonObject
                val mangasJson = jsonResult["data"]?.asJsonArray() ?: return MangasPage(emptyList(), false)
                val hasNext = jsonResult["next"].let {
                    it != null && it !is JsonNull && it.stringValue()?.isNotBlank() == true
                }
                val mangas = mangasJson.mapNotNull { (it as? JsonObject)?.let(::buildMangaFromJson) }
                MangasPage(mangas, hasNext)
            } catch (e: Exception) {
                logcat(LogPriority.ERROR) { "[JsSource:$name] getLatestUpdates (latest.js) error: ${e.message}" }
                MangasPage(emptyList(), false)
            }
        }

        // Fallback: gọi home.js với isLatest = true
        return fetchMangaListFromHome(page, isLatest = true)
    }

    private suspend fun fetchMangaListFromHome(page: Int, isLatest: Boolean): MangasPage {
        val script = scripts["home"] ?: return MangasPage(emptyList(), false)
        var homeResult = if (baseUrl.isNotBlank()) engine.execute(script, "execute", baseUrl, page.toString()) else null
        if (homeResult.isNullOrBlank() || homeResult == "null") {
            homeResult = engine.execute(script, "execute", page.toString())
        }
        if (homeResult.isNullOrBlank() || homeResult == "null") {
            homeResult = engine.execute(script, "execute")
        }
        if (homeResult.isNullOrBlank()) return MangasPage(emptyList(), false)

        return try {
            val jsonResult = json.parseToJsonElement(homeResult).jsonObject
            val data = jsonResult["data"]?.asJsonArray() ?: return MangasPage(emptyList(), false)
            if (data.isEmpty()) return MangasPage(emptyList(), false)

            // Kiểm tra phần tử đầu tiên để biết data là mảng Tab hay mảng Manga
            val firstItem = data.getOrNull(0) as? JsonObject ?: return MangasPage(emptyList(), false)
            val isManga = firstItem.containsKey("cover") || firstItem.containsKey("img") || firstItem.containsKey("thumbnail") || (firstItem.containsKey("name") && firstItem.containsKey("host"))

            if (!isManga) {
                // Đây là một mảng Tab objects
                var tabIndex = 0
                if (isLatest) {
                    var foundIndex = -1
                    for (i in 0 until data.size) {
                        val tabObj = data[i] as? JsonObject ?: continue
                        val title = tabObj["title"]?.stringValue()?.lowercase() ?: tabObj["name"]?.stringValue()?.lowercase() ?: ""
                        if (title.contains("mới") || title.contains("cập nhật") || title.contains("latest") || title.contains("update")) {
                            foundIndex = i
                            break
                        }
                    }
                    tabIndex = if (foundIndex != -1) foundIndex else if (data.size > 1) 1 else 0
                } else {
                    tabIndex = 0
                }

                val tabToUse = data.getOrNull(tabIndex) as? JsonObject
                    ?: data.getOrNull(0) as? JsonObject
                    ?: return MangasPage(emptyList(), false)

                val tabInput = tabToUse["input"]?.stringValue()
                    ?: tabToUse["url"]?.stringValue()
                    ?: tabToUse["link"]?.stringValue()
                    ?: ""
                val tabScriptName = tabToUse["script"]?.stringValue() ?: "gen"
                val scriptKey = tabScriptName.substringBeforeLast(".")
                val tabScript = scripts[scriptKey] ?: scripts["gen"] ?: scripts["home"] ?: scripts.values.firstOrNull()

                if (tabScript != null) {
                    val tabResult = engine.execute(tabScript, "execute", tabInput, page.toString())
                        ?: return MangasPage(emptyList(), false)

                    val tabJsonResult = json.parseToJsonElement(tabResult).jsonObject
                    val mangasJson = tabJsonResult["data"]?.asJsonArray() ?: return MangasPage(emptyList(), false)
                    val hasNext = tabJsonResult["next"].let {
                        it != null && it !is JsonNull && it.stringValue()?.isNotBlank() == true
                    }
                    val mangas = mangasJson.mapNotNull { (it as? JsonObject)?.let(::buildMangaFromJson) }
                    return MangasPage(mangas, hasNext)
                }
                return MangasPage(emptyList(), false)
            }

            // Nếu home.js trả về danh sách manga trực tiếp
            val mangas = data.mapNotNull { (it as? JsonObject)?.let(::buildMangaFromJson) }
            val hasNext = jsonResult["next"].let {
                it != null && it !is JsonNull && it.stringValue()?.isNotBlank() == true
            }
            MangasPage(mangas, hasNext)
        } catch (e: Exception) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] fetchMangaListFromHome error: ${e.message}" }
            MangasPage(emptyList(), false)
        }
    }

    // ─── getSearchManga ───────────────────────────────────────────────────────

    override suspend fun getSearchManga(page: Int, query: String, filters: eu.kanade.tachiyomi.source.model.FilterList): MangasPage {
        val script = scripts["search"] ?: return MangasPage(emptyList(), false)
        val result = engine.execute(script, "execute", query, page.toString())
            ?: return MangasPage(emptyList(), false)

        return try {
            val jsonResult = json.parseToJsonElement(result).jsonObject
            val mangasJson = jsonResult["data"]?.asJsonArray() ?: return MangasPage(emptyList(), false)
            val hasNext = jsonResult["next"].let {
                it != null && it !is JsonNull && it.stringValue()?.isNotBlank() == true
            }
            val mangas = mangasJson.mapNotNull { (it as? JsonObject)?.let(::buildMangaFromJson) }
            MangasPage(mangas, hasNext)
        } catch (e: Exception) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] getSearchManga error: ${e.message}" }
            MangasPage(emptyList(), false)
        }
    }

    suspend fun getHomeTabs(): List<Map<String, String>> {
        val script = scripts["home"] ?: return emptyList()
        var homeResult = if (baseUrl.isNotBlank()) engine.execute(script, "execute", baseUrl) else null
        if (homeResult.isNullOrBlank() || homeResult == "null") {
            homeResult = engine.execute(script, "execute")
        }
        if (homeResult.isNullOrBlank()) return emptyList()

        return try {
            val jsonResult = json.parseToJsonElement(homeResult).jsonObject
            val data = jsonResult["data"]?.asJsonArray() ?: return emptyList()
            data.mapNotNull { el ->
                val o = el as? JsonObject ?: return@mapNotNull null
                val title = o["title"]?.stringValue() ?: o["name"]?.stringValue() ?: return@mapNotNull null
                val input = o["input"]?.stringValue() ?: o["url"]?.stringValue() ?: o["link"]?.stringValue() ?: ""
                val scriptName = o["script"]?.stringValue() ?: "gen.js"
                mapOf("title" to title, "input" to input, "script" to scriptName)
            }
        } catch (e: Exception) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] getHomeTabs error: ${e.message}" }
            emptyList()
        }
    }

    suspend fun getMangaListByTab(tabInput: String, tabScriptName: String, page: Int): MangasPage {
        val scriptKey = tabScriptName.substringBeforeLast(".")
        val tabScript = scripts[scriptKey] ?: scripts["gen"] ?: scripts["home"] ?: scripts.values.firstOrNull()
            ?: return MangasPage(emptyList(), false)
        val tabResult = engine.execute(tabScript, "execute", tabInput, page.toString())
            ?: return MangasPage(emptyList(), false)
        return try {
            val tabJsonResult = json.parseToJsonElement(tabResult).jsonObject
            val mangasJson = tabJsonResult["data"]?.asJsonArray() ?: return MangasPage(emptyList(), false)
            val hasNext = tabJsonResult["next"].let {
                it != null && it !is JsonNull && it.stringValue()?.isNotBlank() == true
            }
            val mangas = mangasJson.mapNotNull { (it as? JsonObject)?.let(::buildMangaFromJson) }
            MangasPage(mangas, hasNext)
        } catch (e: Exception) {
            logcat(LogPriority.ERROR) { "[JsSource:$name] getMangaListByTab error: ${e.message}" }
            MangasPage(emptyList(), false)
        }
    }
}
