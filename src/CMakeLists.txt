cmake_minimum_required(VERSION 3.10)
project(nitro_printing_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NITRO_NATIVE "/Users/shreemanarjunsahu/.puro/shared/pub_cache/hosted/pub.dev/nitro-0.4.2/src/native")
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_printing SHARED
  "nitro_printing.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_printing.bridge.g.cpp"
  "dart_api_dl.c"
)

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
