package dev.shreeman.nitro_printing

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import nitro.nitro_printing_module.NitroPrintingJniBridge

class NitroPrintingPlugin : FlutterPlugin, ActivityAware {

    companion object {
        init { System.loadLibrary("nitro_printing") }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NitroPrintingJniBridge.register(NitroPrintingImpl(), binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NitroPrintingJniBridge.onDetached()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        NitroPrintingJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        NitroPrintingJniBridge.onActivityDetached()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        NitroPrintingJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivity() {
        NitroPrintingJniBridge.onActivityDetached()
    }
}
