import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var documentPicker: DocumentPicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BulkSendDocumentPicker") {
      documentPicker = DocumentPicker(registrar: registrar)
    }
  }
}

/// 파일·폴더를 복사 없이(열기 모드) 고르고, 보안 범위 접근을 열어 둔 채 경로를 돌려준다.
/// - file_picker 는 고른 파일을 앱 임시폴더로 복사해서 대량이면 저장공간이 부족해진다.
/// - file_picker 의 폴더 선택은 경로만 넘겨 dart:io 로 다른 앱/iCloud 폴더를 읽을 수 없다.
/// 접근은 앱이 종료될 때까지 유지한다(1회용 앱이라 stopAccessing 은 호출하지 않음).
class DocumentPicker: NSObject, UIDocumentPickerDelegate {
  private weak var registrar: FlutterPluginRegistrar?
  private var pending: FlutterResult?
  private var multiple = false

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
    let channel = FlutterMethodChannel(name: "bulksend/picker", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "pickFolder": self?.present(types: [.folder], multiple: false, result: result)
      // .data: 일반 파일만 (폴더·패키지는 제외)
      case "pickFiles": self?.present(types: [.data], multiple: true, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func present(types: [UTType], multiple: Bool, result: @escaping FlutterResult) {
    guard pending == nil, let vc = registrar?.viewController else { return result(nil) }
    pending = result
    self.multiple = multiple
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
    picker.allowsMultipleSelection = multiple
    picker.delegate = self
    vc.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let paths = urls.map { url -> String in
      _ = url.startAccessingSecurityScopedResource()
      return url.path
    }
    finish(multiple ? paths : paths.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(multiple ? [String]() : nil)
  }

  private func finish(_ value: Any?) {
    pending?(value)
    pending = nil
  }
}
