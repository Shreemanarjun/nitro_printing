//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <nitro_printing/nitro_printing_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) nitro_printing_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "NitroPrintingPlugin");
  nitro_printing_plugin_register_with_registrar(nitro_printing_registrar);
}
