package com.vbook.reader.engine

import app.cash.quickjs.QuickJs
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import logcat.LogPriority
import logcat.logcat
import okhttp3.OkHttpClient
import org.jsoup.Jsoup
import java.io.File

class VBookEngine(
    private val client: OkHttpClient,
    private val rootDir: File,
    val baseUrl: String = "",
) : AutoCloseable {

    private val jsEnv = JsEnvironment(client)
    private val elementsMap = mutableMapOf<Int, org.jsoup.select.Elements>()
    private var nextId = 0
    private val mutex = Mutex()

    private fun setupBindings(quickJs: QuickJs) {
        quickJs.set("AndroidApp", AndroidAppBridge::class.java, object : AndroidAppBridge {
            override fun fetch(url: String, optionsJson: String): String {
                return try {
                    val options = parseRequestOptions(optionsJson)
                    val response = jsEnv.fetch(url, options)
                    buildString {
                        append("{")
                        append("\"ok\":${response.ok},")
                        append("\"status\":${response.status},")
                        append("\"headers\":${Json.encodeToString(response.headers)},")
                        append("\"text\":${org.json.JSONObject.quote(response.text())}")
                        append("}")
                    }
                } catch (e: Exception) {
                    logcat(LogPriority.ERROR) { "AndroidApp.fetch error: ${e.message}" }
                    """{"ok":false,"status":500,"headers":{},"text":""}"""
                }
            }

            override fun fetchBase64(url: String, optionsJson: String): String {
                return try {
                    val options = parseRequestOptions(optionsJson)
                    val bytes = jsEnv.fetchBytes(url, options)
                    android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                } catch (e: Exception) {
                    ""
                }
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
                val doc = Jsoup.parse(html, baseUri)
                val id = nextId++
                elementsMap[id] = org.jsoup.select.Elements(doc)
                return id
            }

            override fun jsoupSelect(id: Int, selector: String): Int {
                val parent = elementsMap[id] ?: return -1
                val childId = nextId++
                elementsMap[childId] = parent.select(selector)
                return childId
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
                val childId = nextId++
                elementsMap[childId] = org.jsoup.select.Elements()
                return childId
            }

            override fun jsoupFirst(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val first = parent.first() ?: return createEmptyElements()
                val childId = nextId++
                elementsMap[childId] = org.jsoup.select.Elements(first)
                return childId
            }

            override fun jsoupLast(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val last = parent.last() ?: return createEmptyElements()
                val childId = nextId++
                elementsMap[childId] = org.jsoup.select.Elements(last)
                return childId
            }

            override fun jsoupSize(id: Int): Int {
                return elementsMap[id]?.size ?: 0
            }

            override fun jsoupGet(id: Int, index: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val element = parent.getOrNull(index) ?: return createEmptyElements()
                val childId = nextId++
                elementsMap[childId] = org.jsoup.select.Elements(element)
                return childId
            }

            override fun jsoupParent(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val p = parent.first()?.parent() ?: return createEmptyElements()
                val childId = nextId++
                elementsMap[childId] = org.jsoup.select.Elements(p)
                return childId
            }

            override fun jsoupChildren(id: Int): Int {
                val parent = elementsMap[id] ?: return createEmptyElements()
                val c = parent.first()?.children() ?: return createEmptyElements()
                val childId = nextId++
                elementsMap[childId] = c
                return childId
            }

            override fun jsoupHasClass(id: Int, className: String): Boolean {
                return elementsMap[id]?.hasClass(className) ?: false
            }

            override fun sleep(ms: Int) {
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
        } catch (_: Exception) {
            JsRequestOptions()
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

    suspend fun execute(script: String, functionName: String, vararg args: Any?): String? =
        withContext(kotlinx.coroutines.Dispatchers.IO) {
            mutex.withLock {
                try {
                    val finalScript = preprocessScript(script, rootDir)

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
                            if (typeof $functionName === 'function') {
                                var res = $functionName($jsArgs);
                                if (typeof res === 'object' && res !== null) {
                                    return JSON.stringify(res);
                                }
                                return res;
                            } else {
                                return null;
                            }
                        })();
                    """.trimIndent()

                    var quickJs: QuickJs? = null
                    try {
                        quickJs = QuickJs.create()
                        setupBindings(quickJs)
                        val res = quickJs.evaluate(callScript)?.toString()
                        res
                    } finally {
                        quickJs?.close()
                        elementsMap.clear() // Prevent memory leak of JSoup Elements
                    }
                } catch (e: Exception) {
                    logcat(LogPriority.ERROR) { "JS Error in $functionName: ${e.message}" }
                    elementsMap.clear() // Prevent memory leak even on error
                    null
                }
            }
        }

    override fun close() {
        // No-op. QuickJs is now managed inside execute()
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
