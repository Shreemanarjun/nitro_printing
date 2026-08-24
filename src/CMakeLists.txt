cmake_minimum_required(VERSION 3.10)
project(nitro_printing_library VERSION 0.0.1 LANGUAGES C CXX)

# ── Optimization guard ───────────────────────────────────────────────────────
# The Android Gradle Plugin passes the VARIANT name (e.g. "profile") as
# CMAKE_BUILD_TYPE. CMake only defines per-config flags for
# Debug/Release/RelWithDebInfo/MinSizeRel — an unknown config has EMPTY flag
# sets, so every native source silently compiles at -O0. Flutter's release
# variant maps to RELEASE and is unaffected, but profile builds shipped
# unoptimized native code. Give any non-standard config Release-grade flags.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _NITRO_CFG)
if(NOT "${_NITRO_CFG}" MATCHES "^(DEBUG|RELEASE|RELWITHDEBINFO|MINSIZEREL|)$")
  set(CMAKE_C_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
  set(CMAKE_CXX_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM d4097bed03d961ab
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_printing SHARED
  "nitro_printing.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_printing.bridge.g.cpp"
  "dart_api_dl.c"
)

if(NOT ANDROID)
  # The desktop impl source is chosen by the including platform CMakeLists
  # (windows/ or linux/) via NITRO_IMPL_SRC_<lib>: windows/src/ and linux/src/
  # each carry their own HybridNitroPrinting.cpp. The web impl lives in
  # web/src/ (built by web/build_web.sh) — there is no shared src/ impl.
  if(NOT DEFINED NITRO_IMPL_SRC_nitro_printing)
    message(FATAL_ERROR "NITRO_IMPL_SRC_nitro_printing is not set — the platform CMakeLists (windows/ or linux/) must point it at its src/HybridNitroPrinting.cpp")
  endif()
  target_sources(nitro_printing PRIVATE "${NITRO_IMPL_SRC_nitro_printing}")
endif()
if(NOT ANDROID)
  target_sources(nitro_printing PRIVATE "HybridNitroPrinting.cpp")
endif()
target_include_directories(nitro_printing PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(nitro_printing PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(nitro_printing PRIVATE android log)
  target_link_options(nitro_printing PRIVATE "-Wl,-z,max-page-size=16384")
endif()
