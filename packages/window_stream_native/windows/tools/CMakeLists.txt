# wsn_probe: Windows window-stream probes, the test window and the C ABI
# harness. Standalone (not part of the Flutter build):
#   cmake -S packages/window_stream_native/windows/tools -B <build> -G Ninja
cmake_minimum_required(VERSION 3.20)
project(wsn_tools LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

file(GLOB WSN_CORE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/core/*.cpp")
file(GLOB WSN_PROBE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/probe_*.cpp")

add_executable(wsn_probe wsn_probe.cpp ${WSN_PROBE_SOURCES} ${WSN_CORE_SOURCES})
target_include_directories(wsn_probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/../../src")
target_compile_definitions(wsn_probe PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(wsn_probe PRIVATE /EHsc /utf-8 /W3 /permissive- /bigobj /Zc:__cplusplus)
target_link_libraries(wsn_probe PRIVATE
  windowsapp d3d11 dxgi dwmapi shcore windowscodecs propsys shlwapi uiautomationcore
  mfplat mfuuid mf strmiids ole32 oleaut32 user32 gdi32 shell32 advapi32 comctl32 comdlg32
  wtsapi32 version dbghelp mmdevapi winmm)
set_target_properties(wsn_probe PROPERTIES LINK_FLAGS "/SUBSYSTEM:CONSOLE")
