import Flutter
import UIKit

public class SwiftNitroPrintingPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroPrintingRegistry.register(NitroPrintingImpl())
    }
}
