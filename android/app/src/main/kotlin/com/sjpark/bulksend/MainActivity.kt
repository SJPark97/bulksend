package com.sjpark.bulksend

import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 갤러리 폴더에 직접 쓴 파일을 미디어 스캔한다.
        // 수정시각을 원래 날짜로 맞춘 뒤 스캔해야 스캐너가 EXIF 촬영일을 버리지 않는다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bulksend/media")
            .setMethodCallHandler { call, result ->
                if (call.method != "scanFile") return@setMethodCallHandler result.notImplemented()
                val path = call.argument<String>("path")!!
                MediaScannerConnection.scanFile(this, arrayOf(path), null) { _, uri ->
                    // 스캔 완료 콜백은 바인더 스레드에서 오므로 메인 스레드에서 응답한다
                    runOnUiThread { result.success(uri?.toString()) }
                }
            }
    }
}
