set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")

# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "nitro_printing")
project(${PROJECT_NAME} LANGUAGES CXX)

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
# The Linux implementation of HybridNitroPrinting (TCP socket transport +
# registration) is the SHARED desktop source ../src/HybridNitroPrinting.cpp,
# compiled into the `nitro_printing` target by ../src/CMakeLists.txt —
# there is intentionally no Linux-local impl source here.
set(NITRO_IMPL_SRC_nitro_printing "${CMAKE_CURRENT_SOURCE_DIR}/src/HybridNitroPrinting.cpp")
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(nitro_printing_bundled_libraries
  # Defined in ../src/CMakeLists.txt.
  $<TARGET_FILE:nitro_printing>
  PARENT_SCOPE
)
