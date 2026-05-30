import FlutterMacOS
import AppKit

public class SwiftNitroPrintingPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroPrintingRegistry.register(NitroPrintingImpl())
    }
}
