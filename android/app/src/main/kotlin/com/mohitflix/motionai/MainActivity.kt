package com.mohitflix.motionai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MediaBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
}
