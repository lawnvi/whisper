# Builds libwindow_stream_native.so, loaded from Dart with DynamicLibrary.open.
#
# Layout (sources are globbed, new files need no edit here):
#   common/            main-loop helpers, callbacks, logging, dlopen loaders
#   receiver/          streamed windows shown here (GTK, FFmpeg, PulseAudio)
#   capture/           this desktop as a source (PipeWire, GNOME Shell)
#   exports_surface.cc C ABI, receiver half
#   exports_capture.cc C ABI, capture half
#
# FFmpeg, PulseAudio and PipeWire are opened at run time (dlopen), so they
# are not link dependencies; PipeWire's headers are used when installed.
cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "window_stream_native")
project(${PROJECT_NAME} LANGUAGES C CXX)

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)
pkg_check_modules(GIO_UNIX REQUIRED IMPORTED_TARGET gio-unix-2.0)
# Headers only: libpipewire is dlopened at run time, never linked. Without
# them this desktop cannot be a window source (wsn_capture_supported() is 0),
# so a build machine missing libpipewire-0.3-dev must say so loudly.
pkg_check_modules(PIPEWIRE_HEADERS QUIET libpipewire-0.3)
if(NOT PIPEWIRE_HEADERS_FOUND)
  message(WARNING "window_stream_native: libpipewire-0.3 headers not found (install libpipewire-0.3-dev). "
                  "This build cannot share this desktop's windows (GNOME window source disabled).")
endif()

file(GLOB_RECURSE WSN_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/common/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/common/*.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/receiver/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/receiver/*.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/capture/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/capture/*.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/exports_*.cc"
)

add_library(${PROJECT_NAME} SHARED ${WSN_SOURCES})
target_compile_features(${PROJECT_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PROJECT_NAME} PRIVATE WSN_BUILDING)
target_include_directories(${PROJECT_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden)
target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wno-unused-parameter)
target_link_libraries(${PROJECT_NAME} PRIVATE
  PkgConfig::GTK PkgConfig::GIO PkgConfig::GIO_UNIX Threads::Threads ${CMAKE_DL_LIBS})
if(PIPEWIRE_HEADERS_FOUND)
  target_compile_definitions(${PROJECT_NAME} PRIVATE WSN_HAVE_PIPEWIRE_HEADERS)
  target_include_directories(${PROJECT_NAME} PRIVATE ${PIPEWIRE_HEADERS_INCLUDE_DIRS})
endif()

set(window_stream_native_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  PARENT_SCOPE
)
