cmake_minimum_required(VERSION 3.14)
project(whisper_cloud_files LANGUAGES CXX)

# Mounting other devices' files as Cloud Files sync roots. A library of its
# own, loaded with dart:ffi only when something is mounted: it needs C++20
# and exceptions for C++/WinRT, which the runner is not built with.
add_library(whisper_cloud_files SHARED "cloud_files_bridge.cpp")
target_compile_features(whisper_cloud_files PRIVATE cxx_std_20)
target_compile_options(whisper_cloud_files PRIVATE /W4 /WX /EHsc /utf-8)
target_compile_definitions(whisper_cloud_files PRIVATE NOMINMAX)
target_link_libraries(whisper_cloud_files PRIVATE
  "cldapi.lib" "windowsapp.lib" "advapi32.lib")
