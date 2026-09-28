import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var folderPicker: FolderPicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BulkSendFolderPicker") {
      folderPicker = FolderPicker(registrar: registrar)
    }
  }
}

/// 폴더 선택 후 보안 범위 접근을 열어 두고 경로를 돌려준다.
/// file_picker 의 getDirectoryPath 는 경로만 넘겨서 dart:io 로 다른 앱/iCloud 폴더를 읽을 수 없다.
/// 접근은 앱이 종료될 때까지 유지한다(1회용 앱이라 stopAccessing 은 호출하지 않음).
class FolderPicker: NSObject, UIDocumentPickerDelegate {
  private weak var registrar: FlutterPluginRegistrar?
  private var pending: FlutterResult?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
    let channel = FlutterMethodChannel(name: "bulksend/folder", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pickFolder" else { return result(FlutterMethodNotImplemented) }
      self?.present(result)
    }
  }

  private func present(_ result: @escaping FlutterResult) {
    guard pending == nil, let vc = registrar?.viewController else { return result(nil) }
    pending = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    vc.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return finish(nil) }
    _ = url.startAccessingSecurityScopedResource()
    finish(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  private func finish(_ path: String?) {
    pending?(path)
    pending = nil
  }
}
