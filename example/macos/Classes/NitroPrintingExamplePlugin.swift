import FlutterMacOS
import Foundation

public class NitroPrintingExamplePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    nitro_printing_exampleRegistry.register(nitro_printing_exampleModuleImpl())
    // Nitro registration will be injected here by nitrogen link.
  }
}
