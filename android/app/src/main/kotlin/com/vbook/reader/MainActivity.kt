package com.vbook.reader

import android.content.pm.PackageManager
import android.os.Build
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val COOKIE_CHANNEL = "com.vbook.reader/cookie_manager"
    private val APP_IDENTITY_CHANNEL = "com.vbook.reader/app_identity"
    
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
