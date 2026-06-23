set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")

# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "nitro_printing")
project(${PROJECT_NAME} LANGUAGES CXX)

# CUPS is required for Linux printing.
find_package(PkgConfig REQUIRED)
pkg_check_modules(CUPS REQUIRED cups)

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# Linux plugin implementation source.
target_sources(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/src/HybridNitroPrinting.cpp"
)

# Link CUPS into the plugin target.
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${NITRO_NATIVE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  ${CUPS_INCLUDE_DIRS}
)
target_compile_options(${PLUGIN_NAME} PRIVATE ${CUPS_CFLAGS_OTHER})
target_link_libraries(${PLUGIN_NAME} PRIVATE ${CUPS_LIBRARIES})

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(nitro_printing_bundled_libraries
  # Defined in ../src/CMakeLists.txt.
  $<TARGET_FILE:nitro_printing>
  PARENT_SCOPE
)
