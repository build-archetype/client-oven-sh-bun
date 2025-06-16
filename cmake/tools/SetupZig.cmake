if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
  set(DEFAULT_ZIG_ARCH "aarch64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "amd64|x86_64|x64|AMD64")
  set(DEFAULT_ZIG_ARCH "x86_64")
else()
  unsupported(CMAKE_SYSTEM_PROCESSOR)
endif()

if(APPLE)
  set(DEFAULT_ZIG_TARGET ${DEFAULT_ZIG_ARCH}-macos-none)
elseif(WIN32)
  set(DEFAULT_ZIG_TARGET ${DEFAULT_ZIG_ARCH}-windows-msvc)
elseif(LINUX)
  if(ABI STREQUAL "musl")
    set(DEFAULT_ZIG_TARGET ${DEFAULT_ZIG_ARCH}-linux-musl)
  else()
    set(DEFAULT_ZIG_TARGET ${DEFAULT_ZIG_ARCH}-linux-gnu)
  endif()
else()
  unsupported(CMAKE_SYSTEM_NAME)
endif()

set(ZIG_COMMIT "a207204ee57a061f2fb96c7bae0c491b609e73a5")
optionx(ZIG_TARGET STRING "The zig target to use" DEFAULT ${DEFAULT_ZIG_TARGET})

if(CMAKE_BUILD_TYPE STREQUAL "Release")
  if(ENABLE_ASAN)
    set(DEFAULT_ZIG_OPTIMIZE "ReleaseSafe")
  else()
    set(DEFAULT_ZIG_OPTIMIZE "ReleaseFast")
  endif()
elseif(CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
  set(DEFAULT_ZIG_OPTIMIZE "ReleaseSafe")
elseif(CMAKE_BUILD_TYPE STREQUAL "MinSizeRel")
  set(DEFAULT_ZIG_OPTIMIZE "ReleaseSmall")
elseif(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(DEFAULT_ZIG_OPTIMIZE "Debug")
else()
  unsupported(CMAKE_BUILD_TYPE)
endif()

# Since Bun 1.1, Windows has been built using ReleaseSafe.
# This is because it caught more crashes, but we can reconsider this in the future
if(WIN32 AND DEFAULT_ZIG_OPTIMIZE STREQUAL "ReleaseFast")
  set(DEFAULT_ZIG_OPTIMIZE "ReleaseSafe")
endif()

optionx(ZIG_OPTIMIZE "ReleaseFast|ReleaseSafe|ReleaseSmall|Debug" "The Zig optimize level to use" DEFAULT ${DEFAULT_ZIG_OPTIMIZE})

# To use LLVM bitcode from Zig, more work needs to be done. Currently, an install of
# LLVM 18.1.7 does not compatible with what bitcode Zig 0.13 outputs (has LLVM 18.1.7)
# Change to "bc" to experiment, "Invalid record" means it is not valid output.
optionx(ZIG_OBJECT_FORMAT "obj|bc" "Output file format for Zig object files" DEFAULT obj)

# Use overrides from cache manager if set, otherwise use defaults
if(DEFINED ZIG_LOCAL_CACHE_DIR_OVERRIDE)
  optionx(ZIG_LOCAL_CACHE_DIR FILEPATH "The path to local the zig cache directory" DEFAULT ${ZIG_LOCAL_CACHE_DIR_OVERRIDE})
  optionx(ZIG_GLOBAL_CACHE_DIR FILEPATH "The path to the global zig cache directory" DEFAULT ${ZIG_GLOBAL_CACHE_DIR_OVERRIDE})
  # Ensure the override directories exist
  file(MAKE_DIRECTORY ${ZIG_LOCAL_CACHE_DIR_OVERRIDE})
  file(MAKE_DIRECTORY ${ZIG_GLOBAL_CACHE_DIR_OVERRIDE})
  message(STATUS "Using ephemeral Zig cache directories:")
  message(STATUS "  Local: ${ZIG_LOCAL_CACHE_DIR_OVERRIDE}")
  message(STATUS "  Global: ${ZIG_GLOBAL_CACHE_DIR_OVERRIDE}")
elseif(CMAKE_CURRENT_SOURCE_DIR MATCHES "My Shared Files")
  # Auto-detect Tart mounted directories and use VM-local cache to avoid AccessDenied errors
  # Zig translate-c and other operations don't work well on mounted filesystems
  set(TART_VM_LOCAL_CACHE_DIR "/tmp/zig-cache/local")
  set(TART_VM_GLOBAL_CACHE_DIR "/tmp/zig-cache/global")
  optionx(ZIG_LOCAL_CACHE_DIR FILEPATH "The path to local the zig cache directory" DEFAULT ${TART_VM_LOCAL_CACHE_DIR})
  optionx(ZIG_GLOBAL_CACHE_DIR FILEPATH "The path to the global zig cache directory" DEFAULT ${TART_VM_GLOBAL_CACHE_DIR})
  file(MAKE_DIRECTORY ${TART_VM_LOCAL_CACHE_DIR})
  file(MAKE_DIRECTORY ${TART_VM_GLOBAL_CACHE_DIR})
  message(STATUS "🔧 Detected Tart mounted directory - using VM-local Zig cache directories:")
  message(STATUS "  Local: ${TART_VM_LOCAL_CACHE_DIR}")
  message(STATUS "  Global: ${TART_VM_GLOBAL_CACHE_DIR}")
  message(STATUS "  (This avoids AccessDenied errors during Zig translate-c operations)")
elseif(CI AND APPLE)
  # For CI on macOS, use build directory for reliable permissions
  optionx(ZIG_LOCAL_CACHE_DIR FILEPATH "The path to local the zig cache directory" DEFAULT ${BUILD_PATH}/cache/zig/local)
  optionx(ZIG_GLOBAL_CACHE_DIR FILEPATH "The path to the global zig cache directory" DEFAULT ${BUILD_PATH}/cache/zig/global)
  file(MAKE_DIRECTORY ${BUILD_PATH}/cache/zig/local)
  file(MAKE_DIRECTORY ${BUILD_PATH}/cache/zig/global)
  message(STATUS "Using macOS CI Zig cache directories:")
  message(STATUS "  Local: ${BUILD_PATH}/cache/zig/local")
  message(STATUS "  Global: ${BUILD_PATH}/cache/zig/global")
else()
  optionx(ZIG_LOCAL_CACHE_DIR FILEPATH "The path to local the zig cache directory" DEFAULT ${BUILD_PATH}/cache/zig/local)
  optionx(ZIG_GLOBAL_CACHE_DIR FILEPATH "The path to the global zig cache directory" DEFAULT ${BUILD_PATH}/cache/zig/global)
  file(MAKE_DIRECTORY ${BUILD_PATH}/cache/zig/local)
  file(MAKE_DIRECTORY ${BUILD_PATH}/cache/zig/global)
  message(STATUS "Using default Zig cache directories:")
  message(STATUS "  Local: ${BUILD_PATH}/cache/zig/local")
  message(STATUS "  Global: ${BUILD_PATH}/cache/zig/global")
endif()

# TEMPORARY FIX: Commented out to avoid Zig compiler crash in Response.zig
# The ReleaseSafe build of the Zig compiler has a known issue analyzing Response.zig
# with "inline else" patterns. Re-enable this once upstream fixes the compiler crash.
# Related to upstream commit 773484a62 (uWS refactoring).
#
# if(CI AND CMAKE_HOST_APPLE)
#   set(ZIG_COMPILER_SAFE_DEFAULT ON)
# else()
#   set(ZIG_COMPILER_SAFE_DEFAULT OFF)
# endif()
#
# optionx(ZIG_COMPILER_SAFE BOOL "Download a ReleaseSafe build of the Zig compiler. Only availble on macos aarch64." DEFAULT ${ZIG_COMPILER_SAFE_DEFAULT})

# Temporary: Always use regular Zig compiler build (not ReleaseSafe)
optionx(ZIG_COMPILER_SAFE BOOL "Download a ReleaseSafe build of the Zig compiler. Only availble on macos aarch64." DEFAULT OFF)

setenv(ZIG_LOCAL_CACHE_DIR ${ZIG_LOCAL_CACHE_DIR})
setenv(ZIG_GLOBAL_CACHE_DIR ${ZIG_GLOBAL_CACHE_DIR})

setx(ZIG_PATH ${VENDOR_PATH}/zig)

if(WIN32)
  setx(ZIG_EXECUTABLE ${ZIG_PATH}/zig.exe)
else()
  setx(ZIG_EXECUTABLE ${ZIG_PATH}/zig)
endif()

set(CMAKE_ZIG_FLAGS
  --cache-dir ${ZIG_LOCAL_CACHE_DIR}
  --global-cache-dir ${ZIG_GLOBAL_CACHE_DIR}
  --zig-lib-dir ${ZIG_PATH}/lib
)

register_command(
  TARGET
    clone-zig
  COMMENT
    "Downloading zig"
  COMMAND
    ${CMAKE_COMMAND}
      -DZIG_PATH=${ZIG_PATH}
      -DZIG_COMMIT=${ZIG_COMMIT}
      -DENABLE_ASAN=${ENABLE_ASAN}
      -DZIG_COMPILER_SAFE=${ZIG_COMPILER_SAFE}
      -P ${CWD}/cmake/scripts/DownloadZig.cmake
  SOURCES
    ${CWD}/cmake/scripts/DownloadZig.cmake
  OUTPUTS
    ${ZIG_EXECUTABLE}
)
