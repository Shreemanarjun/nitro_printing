cmake_minimum_required(VERSION 3.10)
project(nitro_printing_example_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NITRO_NATIVE "/Users/shreemanarjunsahu/personal/flutter_package/nitro_ecosystem/packages/nitro/src/native")

add_library(nitro_printing_example SHARED
  "nitro_printing_example.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_printing_example.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(nitro_printing_example PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
target_compile_definitions(nitro_printing_example PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(nitro_printing_example PRIVATE android log)
  target_link_options(nitro_printing_example PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(nitro_printing_example PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(nitro_printing_example PRIVATE dl pthread)
endif()
