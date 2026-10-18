# Builds window_stream_native.dll, loaded from Dart with DynamicLibrary.open.
#
# Sources: common/ (UI thread, callbacks, logging), receiver/ (streamed
# windows shown on this PC), capture/ (this PC as a window source) and the
# exports_*.cpp shims of src/window_stream_native.h. New files are picked up
# automatically (CONFIGURE_DEPENDS); tools/ is not part of the DLL.
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "window_stream_native")
project(${PROJECT_NAME} LANGUAGES CXX)

file(GLOB_RECURSE WSN_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/common/*.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/receiver/*.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/capture/*.cpp"
)
file(GLOB WSN_EXPORT_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/exports_*.cpp"
)
file(GLOB_RECURSE WSN_HEADERS CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/common/*.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/receiver/*.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/capture/*.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/*.h"
)

add_library(${PROJECT_NAME} SHARED ${WSN_SOURCES} ${WSN_EXPORT_SOURCES} ${WSN_HEADERS})
target_compile_features(${PROJECT_NAME} PRIVATE cxx_std_20)
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_options(${PROJECT_NAME} PRIVATE /EHsc /bigobj /utf-8 /permissive- /Zc:__cplusplus /W3)
target_compile_definitions(${PROJECT_NAME} PRIVATE
  WSN_BUILDING UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN
  _WIN32_WINNT=0x0A00 WINVER=0x0A00
)
target_include_directories(${PROJECT_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)
target_link_libraries(${PROJECT_NAME} PRIVATE
  windowsapp d3d11 dxgi d2d1 dwrite dwmapi shcore windowscodecs propsys shlwapi
  shell32 uiautomationcore ole32 oleaut32 mfplat mfuuid mf mfreadwrite strmiids
  user32 gdi32 msimg32 winmm imm32 advapi32 mmdevapi comctl32
)

# Picked up by the app's CMake so the DLL ships next to whisper.exe.
set(window_stream_native_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  PARENT_SCOPE
)
