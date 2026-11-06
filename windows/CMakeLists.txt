# Project-level configuration.
cmake_minimum_required(VERSION 3.14)

# Allow Firebase SDK to use older CMake requirements without deprecation warnings.
# Firebase's own CMakeLists.txt calls cmake_minimum_required(< 3.10), which triggers
# a CMake deprecation warning. Since we cannot edit third-party SDK files, we
# suppress the warning at the project level instead.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
set(CMAKE_WARN_DEPRECATED OFF CACHE BOOL "Suppress CMake deprecation warnings from third-party packages" FORCE)

# Suppress CMP194 warning about MSVC assembler for ASM language
if(POLICY CMP194)
  cmake_policy(SET CMP194 NEW)
endif()

project(gmwf LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "gmwf")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Visual Studio 2026 (MSVC 14.5x) turns the deprecated <experimental/coroutine> (/await) into a
# hard error (STL1011). The local_auth_windows plugin still uses it; this keeps it compiling
# until the plugin moves to C++20 <coroutine>. Harmless on older toolsets.
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100" /wd"4238")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Ensure extracted firebase_cpp_sdk_windows has CMakeLists.txt before plugins are loaded
set(FIREBASE_SDK_EXTRACTED "${CMAKE_BINARY_DIR}/extracted/firebase_cpp_sdk_windows")
if(EXISTS "${FIREBASE_SDK_EXTRACTED}")
  file(WRITE "${FIREBASE_SDK_EXTRACTED}/CMakeLists.txt" "cmake_minimum_required(VERSION 3.14)\nproject(firebase_cpp_sdk CXX)\nset(FIREBASE_SDK_DIR \"\${CMAKE_CURRENT_SOURCE_DIR}\")\ninclude_directories(\"\${FIREBASE_SDK_DIR}/include\")\nforeach(lib firebase_app firebase_auth firebase_remote_config firebase_storage firebase_firestore firebase_database firebase_app_check)\n  if(NOT TARGET \${lib})\n    add_library(\${lib} STATIC IMPORTED GLOBAL)\n    set_target_properties(\${lib} PROPERTIES INTERFACE_INCLUDE_DIRECTORIES \"\${FIREBASE_SDK_DIR}/include\" IMPORTED_LOCATION \"\${FIREBASE_SDK_DIR}/libs/windows/VS2019/MD/x64/Debug/\${lib}.lib\" IMPORTED_LOCATION_DEBUG \"\${FIREBASE_SDK_DIR}/libs/windows/VS2019/MD/x64/Debug/\${lib}.lib\" IMPORTED_LOCATION_RELEASE \"\${FIREBASE_SDK_DIR}/libs/windows/VS2019/MD/x64/Release/\${lib}.lib\" IMPORTED_LOCATION_PROFILE \"\${FIREBASE_SDK_DIR}/libs/windows/VS2019/MD/x64/Release/\${lib}.lib\")\n  endif()\nendforeach()\n")
endif()

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)