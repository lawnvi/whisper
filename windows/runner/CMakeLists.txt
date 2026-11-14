cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "audio_share_plugin.cpp"
  "desktop_clipboard_image_plugin.cpp"
  "desktop_quick_send_plugin.cpp"
  "file_manager_plugin.cpp"
  "flutter_window.cpp"
  "input_service.cpp"
  "input_service_manifest.cpp"
  "input_service_update.cpp"
  "main.cpp"
  "remote_input_plugin.cpp"
  "screenshot_plugin.cpp"
  "single_instance.cpp"
  "utils.cpp"
  "window_theme_plugin.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "ole32.lib" "windowscodecs.lib" "winmm.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "msimg32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "wtsapi32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Ed25519 for the input service's self-update (third_party/monocypher/README.md).
# C, and built with the compiler's default warnings: it is not ours to change.
set(MONOCYPHER_DIR "${CMAKE_SOURCE_DIR}/../third_party/monocypher")
add_library(monocypher STATIC
  "${MONOCYPHER_DIR}/monocypher.c"
  "${MONOCYPHER_DIR}/optional/monocypher-ed25519.c"
)
target_include_directories(monocypher PUBLIC "${MONOCYPHER_DIR}")
target_link_libraries(${BINARY_NAME} PRIVATE monocypher)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
