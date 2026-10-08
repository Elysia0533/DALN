package com.vbook.reader.engine

import app.cash.quickjs.QuickJs
import app.cash.quickjs.QuickJsException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import org.jsoup.Jsoup
import java.io.File
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class VBookEngine(
    private val client: OkHttpClient,
    private val rootDir: File,
    val baseUrl: String = "",
) : AutoCloseable {

    private val jsEnv = JsEnvironment(client)
    private val elementsMap = mutableMapOf<Int, org.jsoup.select.Elements>()
    private var nextId = 0
    private val mutex = Mutex()
    private val closed = AtomicBoolean(false)
    private val unavailable = AtomicBoolean(false)
    private val sessionGeneration = AtomicLong(0L)
    private val executionExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vbook-js-worker").apply { isDaemon = true }
    }

    private fun storeElements(elements: org.jsoup.select.Elements): Int {
        if (elementsMap.size >= MAX_JSOUP_HANDLES) {
            throw JsResourceLimitException("HTML handle")
        }
        val id = nextId++
        elementsMap[id] = elements
        return id
    }

    private fun setupBindings(quickJs: QuickJs) {
        quickJs.set("AndroidApp", AndroidAppBridge::class.java, object : AndroidAppBridge {
            override fun fetch(url: String, optionsJson: String): String {
                val options = parseRequestOptions(optionsJson)
                val response = jsEnv.fetch(url, options)
                return buildString {
                    append("{")
                    append("\"ok\":${response.ok},")
                    append("\"status\":${response.status},")
                    append("\"headers\":${Json.encodeToString(response.headers)},")
                    append("\"text\":${org.json.JSONObject.quote(response.text())}")
                    append("}")
                }
            }

            override fun fetchBase64(url: String, optionsJson: String): String {
                val options = parseRequestOptions(optionsJson)
                val bytes = jsEnv.fetchBytes(url, options)
                return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
            }

            override fun load(path: String): String {
                val canonicalRootDir = rootDir.canonicalFile
                val fileToRead = run {
                    val srcFile = File(File(rootDir, "src"), path).canonicalFile
                    if (srcFile.exists() && srcFile.path.startsWith(canonicalRootDir.path)) return@run srcFile
                    val rootFile = File(rootDir, path).canonicalFile
                    if (rootFile.exists() && rootFile.path.startsWith(canonicalRootDir.path)) return@run rootFile
                    null
                } ?: return ""
                val rawContent = fileToRead.readText()
                return com.vbook.reader.loader.JsLoader.decryptScript(rawContent, baseUrl, "")
            }

            override fun jsoupParse(html: String, baseUri: String): Int {
                if (html.length > MAX_HTML_CHARACTERS) {
                    throw JsResourceLimitException("HTML input")
                }
                val doc = Jsoup.parse(html, baseUri)
                return storeElements(org.jsoup.select.Elements(doc))
            }

            override fun jsoupSelect(id: Int, selector: String): Int {
                val parent = elementsMap[id] ?: return -1
                return storeElements(parent.select(selector))
            }

            override fun jsoupText(id: Int): String {
                return elementsMap[id]?.text() ?: ""
            }

            override fun jsoupHtml(id: Int): String {
                return elementsMap[id]?.html() ?: ""
            }

            override fun jsoupAttr(id: Int, name: String): String {
                val els = elementsMap[id] ?: return ""
                if (name == "src" && els.first()?.tagName() == "img") {
                    // Ưu tiên abs: version để resolve relative URL về absolute
                    // Filter startsWith("http") để loại bỏ data:image/... placeholder
                    val fallback = els.attr("abs:data-src").takeIf { it.startsWith("http") }
                        ?: els.attr("data-src").takeIf { it.isNotBlank() && !it.startsWith("data:") }
                        ?: els.attr("abs:data-original").takeIf { it.startsWith("http") }
                        ?: els.attr("data-original").takeIf { it.isNotBlank() && !it.startsWith("data:") }
                        ?: els.attr("abs:data-lazy-src").takeIf { it.startsWith("http") }
                        ?: els.attr("data-lazy-src").takeIf { it.isNotBlank() && !it.startsWith("data:") }
                    if (fallback != null) return fallback
                }
                if (name.equals("href", ignoreCase = true) || name.equals("src", ignoreCase = true)) {
                    val absUrl = els.attr("abs:$name")
                    if (absUrl.isNotEmpty()) return absUrl
                }
                return els.attr(name)
            }

            override fun jsoupRemove(id: Int) {
                elementsMap.remove(id)
            }

            private fun createEmptyElements(): Int {
                return storeElements(org.jsoup.select.Elements())
            }

            override fun jsoupFirst(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val first = parent.first() ?: return createEmptyElements()
                return storeElements(org.jsoup.select.Elements(first))
            }

            override fun jsoupLast(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val last = parent.last() ?: return createEmptyElements()
                return storeElements(org.jsoup.select.Elements(last))
            }

            override fun jsoupSize(id: Int): Int {
                return elementsMap[id]?.size ?: 0
            }

            override fun jsoupGet(id: Int, index: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val element = parent.getOrNull(index) ?: return createEmptyElements()
                return storeElements(org.jsoup.select.Elements(element))
            }

            override fun jsoupParent(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val p = parent.first()?.parent() ?: return createEmptyElements()
                return storeElements(org.jsoup.select.Elements(p))
            }

            override fun jsoupChildren(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val c = parent.first()?.children() ?: return createEmptyElements()
                return storeElements(c)
            }

            override fun jsoupHasClass(id: Int, className: String): Boolean {
                return elementsMap[id]?.hasClass(className) ?: false
            }

            override fun sleep(ms: Int) {
                if (ms > MAX_HOST_SLEEP_MS) {
                    throw JsResourceLimitException("host sleep")
                }
                Thread.sleep(ms.toLong().coerceAtLeast(0L))
            }
        })

        quickJs.evaluate(
            """
            var BASE_URL = "${baseUrl.trimEnd('/')}";
            var CONFIG_URL = "${baseUrl.trimEnd('/')}";

            var console = {
                log: function() {},
                error: function() {},
                warn: function() {},
                info: function() {},
                debug: function() {}
            };

            // Graphics stub – desktop-only API, not available on Android
            var Graphics = {
                createImage: function(base64) {
                    return { width: 0, height: 0, _base64: base64 };
                },
                createCanvas: function(w, h) {
                    return {
                        width: w, height: h, _parts: [],
                        drawImage: function(img, sx, sy, sw, sh, dx, dy, dw, dh) {
                            this._parts.push({ img: img, sx: sx, sy: sy, sw: sw, sh: sh, dx: dx, dy: dy, dw: dw, dh: dh });
                        },
                        capture: function() { return null; }
                    };
                }
            };

            function wrapJsElement(id) {
                if (id < 0) return null;
                var wrapper = {
                    text: function() { return AndroidApp.jsoupText(id); },
                    html: function() { return AndroidApp.jsoupHtml(id); },
                    outerHtml: function() { return AndroidApp.jsoupHtml(id); },
                    attr: function(name) { return AndroidApp.jsoupAttr(id, name); },
                    select: function(selector) { return wrapJsElement(AndroidApp.jsoupSelect(id, selector)); },
                    find: function(selector) { return wrapJsElement(AndroidApp.jsoupSelect(id, selector)); },
                    remove: function() { AndroidApp.jsoupRemove(id); },
                    first: function() { return wrapJsElement(AndroidApp.jsoupFirst(id)); },
                    last: function() { return wrapJsElement(AndroidApp.jsoupLast(id)); },
                    size: function() { return AndroidApp.jsoupSize(id); },
                    get: function(index) { return wrapJsElement(AndroidApp.jsoupGet(id, index)); },
                    eq: function(index) { return wrapJsElement(AndroidApp.jsoupGet(id, index)); },
                    parent: function() { return wrapJsElement(AndroidApp.jsoupParent(id)); },
                    children: function() { return wrapJsElement(AndroidApp.jsoupChildren(id)); },
                    hasClass: function(className) { return AndroidApp.jsoupHasClass(id, className); },
                    val: function() { return AndroidApp.jsoupAttr(id, "value"); },
                    src: function() { return AndroidApp.jsoupAttr(id, "src"); },
                    href: function() { return AndroidApp.jsoupAttr(id, "href"); },
                    forEach: function(callback) {
                        var size = AndroidApp.jsoupSize(id);
                        for (var i = 0; i < size; i++) {
                            callback(wrapJsElement(AndroidApp.jsoupGet(id, i)), i);
                        }
                    },
                    toArray: function() {
                        var list = [];
                        var size = AndroidApp.jsoupSize(id);
                        for (var i = 0; i < size; i++) {
                            list.push(wrapJsElement(AndroidApp.jsoupGet(id, i)));
                        }
                        return list;
                    },
                    map: function(callback) {
                        var list = [];
                        var size = AndroidApp.jsoupSize(id);
                        for (var i = 0; i < size; i++) {
                            list.push(callback(wrapJsElement(AndroidApp.jsoupGet(id, i)), i));
                        }
                        return list;
                    },
                    filter: function(callback) {
                        var list = [];
                        var size = AndroidApp.jsoupSize(id);
                        for (var i = 0; i < size; i++) {
                            var el = wrapJsElement(AndroidApp.jsoupGet(id, i));
                            if (callback(el, i)) list.push(el);
                        }
                        return list;
                    },
                    get length() { return AndroidApp.jsoupSize(id); }
                };

                return new Proxy(wrapper, {
                    get: function(target, prop) {
                        if (typeof prop === "string" && /^\d+$/.test(prop)) {
                            var index = parseInt(prop, 10);
                            if (index >= 0 && index < AndroidApp.jsoupSize(id)) {
                                return wrapJsElement(AndroidApp.jsoupGet(id, index));
                            }
                            return undefined;
                        }
                        return target[prop];
                    }
                });
            }

            function normalizeUrl(url) {
                if (url && url.startsWith("/") && typeof BASE_URL !== "undefined") {
                    return BASE_URL + url;
                }
                return url;
            }

            function fetch(url, options) {
                url = normalizeUrl(url);
                var _opts = JSON.stringify(options || {});
                var raw = AndroidApp.fetch(url, _opts);
                var obj = JSON.parse(raw);
                return {
                    ok: obj.ok,
                    status: obj.status,
                    headers: obj.headers || {},
                    text: function() { return obj.text; },
                    html: function() { return wrapJsElement(AndroidApp.jsoupParse(obj.text, url)); },
                    json: function() { try { return JSON.parse(obj.text); } catch(e) { return null; } },
                    base64: function() { return AndroidApp.fetchBase64(url, _opts); }
                };
            }

            var _b64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
            function btoa(input) {
                var str = String(input);
                var output = '';
                for (
                    var block = 0, charCode, i = 0, map = _b64Chars;
                    str.charAt(i | 0) || (map = '=', i % 1);
                    output += map.charAt(63 & block >> 8 - i % 1 * 8)
                ) {
                    charCode = str.charCodeAt(i += 3/4);
                    block = block << 8 | charCode;
                }
                return output;
            }

            function atob(input) {
                var str = String(input).replace(/=+$/, '');
                var output = '';
                if (str.length % 4 == 1) return '';
                for (
                    var bc = 0, bs = 0, buffer, i = 0;
                    buffer = str.charAt(i++);
                    ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer,
                        bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0
                ) {
                    buffer = _b64Chars.indexOf(buffer);
                }
                return output;
            }

            function load(path) {
                var script = AndroidApp.load(path);
                if (script) {
                    (1, eval)(script);
                }
            }

            function createHttpRequest(method, url) {
                var options = { method: method || "GET" };
                return {
                    headers: function(headers) {
                        options.headers = Object.assign({}, options.headers || {}, headers || {});
                        return this;
                    },
                    params: function(params) {
                        options.queries = Object.assign({}, options.queries || {}, params || {});
                        return this;
                    },
                    body: function(body) {
                        options.body = body;
                        return this;
                    },
                    submit: function() { return fetch(url, options); },
                    get: function() { return fetch(url, options); },
                    fetch: function() { return fetch(url, options); },
                    send: function() { return fetch(url, options); },
                    execute: function() { return fetch(url, options); },
                    text: function() { return fetch(url, options).text(); },
                    getText: function() { return fetch(url, options).text(); },
                    string: function() { return fetch(url, options).text(); },
                    html: function() { return fetch(url, options).html(); },
                    getHtml: function() { return fetch(url, options).html(); },
                    json: function() { return fetch(url, options).json(); }
                };
            }

            var Response = {
                success: function(data, next) {
                    return JSON.stringify({ data: data, next: next });
                },
                error: function(msg) {
                    return JSON.stringify({ error: msg });
                }
            };

            var Http = {
                get: function(url) { return createHttpRequest("GET", url); },
                post: function(url, options) {
                    var request = createHttpRequest("POST", url);
                    if (options && options.headers) request.headers(options.headers);
                    if (options && options.queries) request.params(options.queries);
                    if (options && options.body !== undefined) request.body(options.body);
                    return request;
                },
                put: function(url) { return createHttpRequest("PUT", url); },
                delete: function(url) { return createHttpRequest("DELETE", url); },
                patch: function(url) { return createHttpRequest("PATCH", url); }
            };

            var Console = {
                log: function(msg) { }
            };
            var console = Console;

            var UserAgent = {
                chrome: function() { return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"; },
                android: function() { return "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"; },
                system: function() { return "okhttp/4.12.0"; }
            };

            function sleep(ms) {
                AndroidApp.sleep(Math.max(0, ms | 0));
            }

            var Html = {
                parse: function(htmlStr, baseUrl) {
                    return wrapJsElement(AndroidApp.jsoupParse(htmlStr, baseUrl || BASE_URL || ""));
                },
                clean: function(htmlStr) {
                    return htmlStr;
                },
                decode: function(str) {
                    if (!str) return "";
                    return str
                        .replace(/&amp;/g, '&')
                        .replace(/&lt;/g, '<')
                        .replace(/&gt;/g, '>')
                        .replace(/&quot;/g, '"')
                        .replace(/&#39;/g, "'")
                        .replace(/&nbsp;/g, " ");
                },
                unescape: function(str) {
                    return this.decode(str);
                }
            };
            """.trimIndent(),
        )
    }

    private fun parseRequestOptions(optionsJson: String): JsRequestOptions {
        if (optionsJson.isBlank()) return JsRequestOptions()
        return try {
            val obj = Json.parseToJsonElement(optionsJson) as? JsonObject ?: return JsRequestOptions()
            JsRequestOptions(
                method = obj["method"]?.jsonPrimitiveOrNull()?.content ?: "GET",
                headers = obj["headers"].jsonObjectOrNull()
                    ?.mapValues { it.value.jsonPrimitiveOrNull()?.content ?: it.value.toString() }
                    ?: emptyMap(),
                queries = obj["queries"].jsonObjectOrNull()
                    ?.mapValues { it.value.jsonPrimitiveOrNull()?.content ?: it.value.toString() }
                    ?: emptyMap(),
                body = obj["body"],
            )
        } catch (e: Exception) {
            throw JsScriptException("request options", e)
        }
    }

    private fun JsonElement?.jsonObjectOrNull(): JsonObject? = this as? JsonObject

    private fun JsonElement?.jsonPrimitiveOrNull(): JsonPrimitive? = this as? JsonPrimitive

    private fun preprocessScript(script: String, rootDir: File): String {
        val loadRegex = Regex("""load\(['"](.*?)['"]\);?""")
        var result = script
        var match = loadRegex.find(result)
        var maxDepth = 10
        val canonicalRootDir = rootDir.canonicalFile

        while (match != null && maxDepth > 0) {
            val path = match.groupValues[1]
            val srcFile = File(File(rootDir, "src"), path).canonicalFile
            val rootFile = File(rootDir, path).canonicalFile

            val rawContent = when {
                srcFile.exists() && srcFile.path.startsWith(canonicalRootDir.path) -> srcFile.readText()
                rootFile.exists() && rootFile.path.startsWith(canonicalRootDir.path) -> rootFile.readText()
                else -> ""
            }
            val content = com.vbook.reader.loader.JsLoader.decryptScript(rawContent, baseUrl, "")

            result = result.replace(match.value, content)
            match = loadRegex.find(result)
            maxDepth--
        }
        return result
    }

    suspend fun execute(script: String, functionName: String, vararg args: Any?): String? = mutex.withLock {
        currentCoroutineContext().ensureActive()
        ensureAvailable()

        if (!JS_IDENTIFIER.matches(functionName)) {
            throw JsScriptException("invalid function name")
        }

        val finalScript = preprocessScript(script, rootDir)
        if (finalScript.toByteArray(Charsets.UTF_8).size > MAX_SCRIPT_BYTES) {
            throw JsResourceLimitException("JavaScript source")
        }

        val jsArgs = args.joinToString(", ") { arg ->
            when (arg) {
                is String -> Json.encodeToString(arg)
                is Number -> arg.toString()
                is Boolean -> arg.toString()
                else -> "null"
            }
        }

        val callScript = """
            (function() {
                $finalScript
                if (typeof $functionName !== 'function') {
                    throw new Error('Required extension function is missing');
                }
                var result = $functionName($jsArgs);
                if (result !== null &&
                    (typeof result === 'object' || typeof result === 'function') &&
                    typeof result.then === 'function') {
                    return JSON.stringify({ type: 'promise' });
                }
                var serialized = null;
                if (typeof result === 'string') {
                    serialized = result;
                } else if (typeof result !== 'undefined' && result !== null) {
                    serialized = JSON.stringify(result);
                }
                return JSON.stringify({ type: 'value', value: serialized });
            })();
        """.trimIndent()

        val sessionToken = sessionGeneration.incrementAndGet()
        val future = try {
            executionExecutor.submit<String?> {
                evaluateBlocking(callScript, functionName, sessionToken)
            }
        } catch (e: Exception) {
            throw JsEngineUnavailableException()
        }

        awaitExecution(future, functionName, sessionToken)
    }

    private fun ensureAvailable() {
        if (closed.get()) throw JsExecutionCancelledException()
        if (unavailable.get()) throw JsEngineUnavailableException()
    }

    private fun isSessionActive(sessionToken: Long): Boolean =
        !closed.get() && !unavailable.get() && sessionGeneration.get() == sessionToken

    private fun evaluateBlocking(
        callScript: String,
        functionName: String,
        sessionToken: Long,
    ): String? {
        if (!isSessionActive(sessionToken)) throw JsExecutionCancelledException()

        var quickJs: QuickJs? = null
        return try {
            quickJs = QuickJs.create()
            setupBindings(quickJs)
            val envelope = quickJs.evaluate(callScript, "$functionName.js")?.toString()
                ?: throw JsResultParseException(functionName)
            if (!isSessionActive(sessionToken)) throw JsExecutionCancelledException()
            decodeExecutionEnvelope(envelope, functionName)
        } finally {
            quickJs?.close()
            elementsMap.clear()
            nextId = 0
        }
    }

    private fun decodeExecutionEnvelope(envelope: String, functionName: String): String? {
        if (envelope.length > MAX_RESULT_CHARACTERS) {
            throw JsResourceLimitException("JavaScript result")
        }

        val payload = try {
            Json.parseToJsonElement(envelope) as? JsonObject
                ?: throw JsResultParseException(functionName)
        } catch (e: VBookEngineException) {
            throw e
        } catch (e: Exception) {
            throw JsResultParseException(functionName, e)
        }

        return when (payload["type"]?.jsonPrimitiveOrNull()?.content) {
            "promise" -> throw JsAsyncUnsupportedException()
            "value" -> {
                val value = payload["value"]
                if (value == null || value is JsonNull) {
                    null
                } else {
                    val serialized = value.jsonPrimitiveOrNull()?.content
                        ?: throw JsResultParseException(functionName)
                    if (serialized.toByteArray(Charsets.UTF_8).size > MAX_RESULT_BYTES) {
                        throw JsResourceLimitException("JavaScript result")
                    }
                    serialized
                }
            }
            else -> throw JsResultParseException(functionName)
        }
    }

    private suspend fun awaitExecution(
        future: Future<String?>,
        functionName: String,
        sessionToken: Long,
    ): String? = withContext(Dispatchers.IO) {
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(EXECUTION_TIMEOUT_MS)
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                if (!isSessionActive(sessionToken)) {
                    future.cancel(true)
                    throw JsExecutionCancelledException()
                }

                val remainingNanos = deadlineNanos - System.nanoTime()
                if (remainingNanos <= 0L) {
                    disableAfterTimeout(future, functionName)
                }

                try {
                    return@withContext future.get(
                        minOf(remainingNanos, TimeUnit.MILLISECONDS.toNanos(EXECUTION_POLL_MS)),
                        TimeUnit.NANOSECONDS,
                    )
                } catch (_: TimeoutException) {
                    // Poll session state and coroutine cancellation until the deadline.
                }
            }
            @Suppress("UNREACHABLE_CODE")
            null
        } catch (e: CancellationException) {
            unavailable.set(true)
            sessionGeneration.incrementAndGet()
            future.cancel(true)
            executionExecutor.shutdownNow()
            throw e
        } catch (e: InterruptedException) {
            future.cancel(true)
            Thread.currentThread().interrupt()
            throw JsExecutionCancelledException()
        } catch (e: ExecutionException) {
            throw translateExecutionFailure(e.cause ?: e, functionName)
        }
    }

    private fun disableAfterTimeout(future: Future<*>, functionName: String): Nothing {
        unavailable.set(true)
        sessionGeneration.incrementAndGet()
        future.cancel(true)
        executionExecutor.shutdownNow()
        throw JsExecutionTimeoutException(functionName)
    }

    private fun translateExecutionFailure(error: Throwable, functionName: String): VBookEngineException =
        when (error) {
            is VBookEngineException -> error
            is QuickJsException -> JsScriptException(functionName, error)
            is OutOfMemoryError -> JsResourceLimitException("JavaScript memory")
            else -> JsScriptException(functionName, error)
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        sessionGeneration.incrementAndGet()
        executionExecutor.shutdownNow()
        elementsMap.clear()
        nextId = 0
    }

    companion object {
        private const val EXECUTION_TIMEOUT_MS = 30_000L
        private const val EXECUTION_POLL_MS = 100L
        private const val MAX_SCRIPT_BYTES = 2 * 1024 * 1024
        private const val MAX_RESULT_BYTES = 16 * 1024 * 1024
        private const val MAX_RESULT_CHARACTERS = 16 * 1024 * 1024
        private const val MAX_HTML_CHARACTERS = 8 * 1024 * 1024
        private const val MAX_JSOUP_HANDLES = 10_000
        private const val MAX_HOST_SLEEP_MS = 5_000
        private val JS_IDENTIFIER = Regex("^[A-Za-z_$][A-Za-z0-9_$]*$")
    }

    interface AndroidAppBridge {
        fun fetch(url: String, optionsJson: String): String
        fun fetchBase64(url: String, optionsJson: String): String
        fun load(path: String): String
        fun jsoupParse(html: String, baseUri: String): Int
        fun jsoupSelect(id: Int, selector: String): Int
        fun jsoupText(id: Int): String
        fun jsoupHtml(id: Int): String
        fun jsoupAttr(id: Int, name: String): String
        fun jsoupRemove(id: Int)
        fun jsoupFirst(id: Int): Int
        fun jsoupLast(id: Int): Int
        fun jsoupSize(id: Int): Int
        fun jsoupGet(id: Int, index: Int): Int
        fun jsoupParent(id: Int): Int
        fun jsoupChildren(id: Int): Int
        fun jsoupHasClass(id: Int, className: String): Boolean
        fun sleep(ms: Int)
    }
}
