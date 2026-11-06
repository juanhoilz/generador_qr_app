package com.example.generador_qr_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "generador_qr_app/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "info") {
                    result.success(mapOf("modelo" to "${Build.MANUFACTURER} ${Build.MODEL}"))
                } else {
                    result.notImplemented()
                }
            }
    }
}
