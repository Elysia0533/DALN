package com.vbook.reader.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import logcat.logcat
import okhttp3.FormBody
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.jsoup.Jsoup

class JsEnvironment(
    private val client: OkHttpClient,
    private val defaultHeaders: okhttp3.Headers = okhttp3.Headers.Builder()
        .add("User-Agent", "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
        .build(),
) {

    fun fetch(url: String, options: JsRequestOptions = JsRequestOptions()): JsResponse {
        return try {
            val finalUrl = buildUrl(url, options.queries)
            val headersBuilder = defaultHeaders.newBuilder()
            
            // Sync active cookies from Android WebView CookieManager (handles Cloudflare cf_clearance & session cookies)
            try {
                val cookieManager = android.webkit.CookieManager.getInstance()
                val webViewCookies = cookieManager.getCookie(finalUrl)
                if (!webViewCookies.isNullOrBlank()) {
                    headersBuilder.set("Cookie", webViewCookies)
                }
            } catch (e: Exception) {
                // Ignore WebView CookieManager access on non-Android test environments
            }

            options.headers.forEach { (key, value) -> headersBuilder.set(key, value) }

            val method = options.method.ifBlank { "GET" }.uppercase()
            val requestBuilder = Request.Builder()
                .url(finalUrl)
                .headers(headersBuilder.build())

            val requestBody = when {
                method == "GET" || method == "HEAD" -> null
                options.body == null -> ByteArray(0).toRequestBody(null)
                options.body is JsonPrimitive && options.body.isString -> {
                    val contentType = options.headers.entries
                        .firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }
                        ?.value
                        ?.toMediaTypeOrNull()
                    options.body.content.toRequestBody(contentType)
                }
                options.body is JsonObject || options.body is JsonArray -> {
                    val contentType = options.headers.entries
                        .firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }
                        ?.value
                        ?.toMediaTypeOrNull()
                    if (contentType?.subtype?.contains("json", ignoreCase = true) == true) {
                        options.body.toString().toRequestBody(contentType)
                    } else {
                        FormBody.Builder().apply {
                            when (options.body) {
                                is JsonObject -> options.body.forEach { (key, value) ->
                                    add(key, value.asRequestValue())
                                }
                                is JsonArray -> options.body.forEachIndexed { index, value ->
                                    add(index.toString(), value.asRequestValue())
                                }
                                else -> Unit
                            }
                        }.build()
                    }
                }
                else -> options.body.toString().toRequestBody(null)
            }

            requestBuilder.method(method, requestBody)
            val response = client.newCall(requestBuilder.build()).execute()
            var bodyContent = response.body?.string() ?: ""

            // Nếu request không thành công (403, 404, 503) hoặc rỗng đối với Hako/DocLN hoặc TruyenQQ, thử fallback domain
            if ((!response.isSuccessful || bodyContent.isBlank()) && (finalUrl.contains("hako") || finalUrl.contains("docln"))) {
                val fallbackUrl = finalUrl.replace(Regex("https?://[^/]+"), "https://docln.sbs")
                if (fallbackUrl != finalUrl) {
                    logcat { "Retrying fetch with fallback domain docln.sbs: $fallbackUrl" }
                    val fallbackRequest = requestBuilder.url(fallbackUrl).build()
                    val fallbackResponse = client.newCall(fallbackRequest).execute()
                    if (fallbackResponse.isSuccessful) {
                        val fallbackContent = fallbackResponse.body?.string() ?: ""
                        if (fallbackContent.isNotBlank()) {
                            return JsResponse(
                                ok = true,
                                status = fallbackResponse.code,
                                headers = fallbackResponse.headers.toMultimap().mapValues { it.value.joinToString(", ") },
                                content = fallbackContent,
                            )
                        }
                    }
                }
            } else if ((!response.isSuccessful || bodyContent.isBlank()) && finalUrl.contains("truyenqq")) {
                val fallbackUrl = finalUrl.replace(Regex("https?://[^/]+"), "https://truyenqqto.com")
                if (fallbackUrl != finalUrl) {
                    logcat { "Retrying fetch with fallback domain truyenqqto.com: $fallbackUrl" }
                    val fallbackRequest = requestBuilder.url(fallbackUrl).build()
                    val fallbackResponse = client.newCall(fallbackRequest).execute()
                    if (fallbackResponse.isSuccessful) {
                        val fallbackContent = fallbackResponse.body?.string() ?: ""
                        if (fallbackContent.isNotBlank()) {
                            return JsResponse(
                                ok = true,
                                status = fallbackResponse.code,
                                headers = fallbackResponse.headers.toMultimap().mapValues { it.value.joinToString(", ") },
                                content = fallbackContent,
                            )
                        }
                    }
                }
            }

            JsResponse(
                ok = response.isSuccessful,
                status = response.code,
                headers = response.headers.toMultimap().mapValues { it.value.joinToString(", ") },
                content = bodyContent,
            )
        } catch (e: Exception) {
            logcat { "Fetch error: ${e.message}" }
            // Thử fallback trực tiếp nếu gặp lỗi kết nối (UnknownHost/Connect)
            if (url.contains("hako") || url.contains("docln")) {
                try {
                    val fallbackUrl = buildUrl(url.replace(Regex("https?://[^/]+"), "https://docln.sbs"), options.queries)
                    val headersBuilder = defaultHeaders.newBuilder()
                    options.headers.forEach { (k, v) -> headersBuilder.set(k, v) }
                    val req = Request.Builder().url(fallbackUrl).headers(headersBuilder.build()).build()
                    val res = client.newCall(req).execute()
                    if (res.isSuccessful) {
                        return JsResponse(true, res.code, res.headers.toMultimap().mapValues { it.value.joinToString(", ") }, res.body?.string() ?: "")
                    }
                } catch (fe: Exception) {
                    logcat { "Fallback fetch also error: ${fe.message}" }
                }
            } else if (url.contains("truyenqq")) {
                try {
                    val fallbackUrl = buildUrl(url.replace(Regex("https?://[^/]+"), "https://truyenqqto.com"), options.queries)
                    val headersBuilder = defaultHeaders.newBuilder()
                    options.headers.forEach { (k, v) -> headersBuilder.set(k, v) }
                    val req = Request.Builder().url(fallbackUrl).headers(headersBuilder.build()).build()
                    val res = client.newCall(req).execute()
                    if (res.isSuccessful) {
                        return JsResponse(true, res.code, res.headers.toMultimap().mapValues { it.value.joinToString(", ") }, res.body?.string() ?: "")
                    }
                } catch (fe: Exception) {
                    logcat { "Fallback fetch also error: ${fe.message}" }
                }
            }
            JsResponse(false, 500, emptyMap(), "")
        }
    }

    /** Fetch raw bytes (used for base64 encoding — cuutruyen image decryption etc.) */
    fun fetchBytes(url: String, options: JsRequestOptions = JsRequestOptions()): ByteArray {
        val finalUrl = buildUrl(url, options.queries)
        val headersBuilder = defaultHeaders.newBuilder()
        options.headers.forEach { (key, value) -> headersBuilder.set(key, value) }
        val request = Request.Builder()
            .url(finalUrl)
            .headers(headersBuilder.build())
            .build()
        return client.newCall(request).execute().use { response ->
            response.body?.bytes() ?: ByteArray(0)
        }
    }

    private fun buildUrl(url: String, queries: Map<String, String>): String {
        var processedUrl = url
        // Tự động chuyển đổi các domain Hako cũ (ln.hako.vn, ln.hako.re...) sang domain mới không bị chặn (docln.sbs)
        if (processedUrl.contains("hako.vn") || processedUrl.contains("hako.re") || processedUrl.contains("hako.is")) {
            processedUrl = processedUrl
                .replace("ln.hako.vn", "docln.sbs")
                .replace("ln.hako.re", "docln.sbs")
                .replace("hako.re", "docln.sbs")
                .replace("hako.vn", "docln.sbs")
                .replace("hako.is", "docln.sbs")
        }

        // Tự động chuyển đổi các domain TruyenQQ cũ sang domain mới không bị chặn (truyenqqto.com)
        if (processedUrl.contains("truyenqq.com") || processedUrl.contains("truyenqq.net") || processedUrl.contains("truyenqq.top") || processedUrl.contains("truyenqqpro.com")) {
            processedUrl = processedUrl
                .replace("truyenqq.com", "truyenqqto.com")
                .replace("truyenqq.net", "truyenqqto.com")
                .replace("truyenqq.top", "truyenqqto.com")
                .replace("truyenqqpro.com", "truyenqqto.com")
        }

        if (queries.isEmpty()) return processedUrl
        val httpUrl = processedUrl.toHttpUrlOrNull() ?: return processedUrl
        val builder = httpUrl.newBuilder()
        queries.forEach { (key, value) -> builder.setQueryParameter(key, value) }
        return builder.build().toString()
    }

    private fun JsonElement.asRequestValue(): String = when (this) {
        is JsonPrimitive -> content
        else -> toString()
    }
}

class JsResponse(
    val ok: Boolean,
    val status: Int,
    val headers: Map<String, String>,
    private val content: String,
) {
    fun text() = content
    fun html() = JsDocumentImpl(Jsoup.parse(content))
}

data class JsRequestOptions(
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val queries: Map<String, String> = emptyMap(),
    val body: JsonElement? = null,
)

interface JsDocument {
    fun select(selector: String): JsElement
    fun html(): String
    fun text(): String
}

interface JsElement {
    fun text(): String
    fun html(): String
    fun attr(name: String): String
    fun select(selector: String): JsElement
    fun remove()
    fun first(): JsElement?
    fun last(): JsElement?
    fun size(): Int
    fun get(index: Int): JsElement?
}

class JsDocumentImpl(private val document: org.jsoup.nodes.Document) : JsDocument {
    override fun select(selector: String): JsElement = JsElementImpl(document.select(selector))
    override fun html() = document.outerHtml()
    override fun text() = document.text()
}

class JsElementImpl(private val elements: org.jsoup.select.Elements) : JsElement {
    override fun text() = elements.text()
    override fun html() = elements.html()
    override fun attr(name: String) = elements.attr(name)
    override fun select(selector: String): JsElement = JsElementImpl(elements.select(selector))
    override fun remove() {
        elements.remove()
    }
    override fun first(): JsElement? = elements.first()?.let { JsElementImpl(org.jsoup.select.Elements(it)) }
    override fun last(): JsElement? = elements.last()?.let { JsElementImpl(org.jsoup.select.Elements(it)) }
    override fun size(): Int = elements.size
    override fun get(index: Int): JsElement? = elements.getOrNull(index)?.let { JsElementImpl(org.jsoup.select.Elements(it)) }
}
