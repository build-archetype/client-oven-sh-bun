optionx(ENABLE_CCACHE BOOL "If ccache should be enabled" DEFAULT ON)

if(NOT ENABLE_CCACHE)
  return()
endif()

if (CI AND NOT APPLE)
  return()
endif()

find_command(
  VARIABLE
    CCACHE_PROGRAM
  COMMAND
    ccache
  REQUIRED
    ${CI}
)

if(NOT CCACHE_PROGRAM)
  return()
endif()

set(CMAKE_C_COMPILER_LAUNCHER ${CCACHE_PROGRAM})
set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE_PROGRAM})

# Use override from cache manager if set, otherwise use defaults
if(DEFINED CCACHE_DIR_OVERRIDE)
  setenv(CCACHE_DIR ${CCACHE_DIR_OVERRIDE})
  # Ensure the override directory exists
  file(MAKE_DIRECTORY ${CCACHE_DIR_OVERRIDE})
  message(STATUS "🔧 Using ccache override directory: ${CCACHE_DIR_OVERRIDE}")
  message(STATUS "🔍 Debug: CCACHE_DIR_OVERRIDE was set by build.mjs persistent cache")
elseif(CMAKE_CURRENT_SOURCE_DIR MATCHES "My Shared Files")
  # Auto-detect Tart mounted directories and use VM-local cache to avoid permission denied errors
  # ccache needs to write cache files which mounted filesystems don't support well
  set(TART_VM_CCACHE_DIR "/tmp/ccache")
  setenv(CCACHE_DIR ${TART_VM_CCACHE_DIR})
  file(MAKE_DIRECTORY ${TART_VM_CCACHE_DIR})
  message(STATUS "🔧 Detected Tart mounted directory - using VM-local ccache directory:")
  message(STATUS "  Directory: ${TART_VM_CCACHE_DIR}")
  message(STATUS "  (This avoids permission denied errors during C++ compilation)")
  message(STATUS "🔍 Debug: Source dir: ${CMAKE_CURRENT_SOURCE_DIR}")
elseif(CI AND APPLE)
  # For CI on macOS, use build directory for reliable permissions
  set(MACOS_CCACHE_DIR ${BUILD_PATH}/cache/ccache)
  setenv(CCACHE_DIR ${MACOS_CCACHE_DIR})
  file(MAKE_DIRECTORY ${MACOS_CCACHE_DIR})
  message(STATUS "🔧 Using macOS CI ccache directory: ${MACOS_CCACHE_DIR}")
  message(STATUS "🔍 Debug: CI=${CI}, APPLE=${APPLE}, BUILD_PATH=${BUILD_PATH}")
else()
  setenv(CCACHE_DIR ${CACHE_PATH}/ccache)
  file(MAKE_DIRECTORY ${CACHE_PATH}/ccache)
  message(STATUS "🔧 Using default ccache directory: ${CACHE_PATH}/ccache")
  message(STATUS "🔍 Debug: CACHE_PATH=${CACHE_PATH}")
endif()

setenv(CCACHE_BASEDIR ${CWD})
setenv(CCACHE_NOHASHDIR 1)
setenv(CCACHE_FILECLONE 1)

if(CI)
  setenv(CCACHE_SLOPPINESS "pch_defines,time_macros,locale,clang_index_store,gcno_cwd,include_file_ctime,include_file_mtime")
else()
  setenv(CCACHE_MAXSIZE 100G)
  setenv(CCACHE_SLOPPINESS "pch_defines,time_macros,locale,random_seed,clang_index_store,gcno_cwd")
endif()

# Debug: Show final ccache configuration
message(STATUS "📊 Final ccache configuration:")
message(STATUS "  CCACHE_DIR=$ENV{CCACHE_DIR}")
message(STATUS "  ENABLE_CCACHE=${ENABLE_CCACHE}")
message(STATUS "  CCACHE_PROGRAM=${CCACHE_PROGRAM}")
message(STATUS "  CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}")
message(STATUS "  CMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER}")

# Add a custom target to show ccache stats after build for debugging
if(CI)
  add_custom_target(ccache-stats
    COMMAND ${CCACHE_PROGRAM} -s || echo "ccache stats not available"
    COMMENT "🔍 Showing ccache statistics for debugging"
    VERBATIM
  )
  
  # Show ccache directory contents for debugging
  add_custom_target(ccache-debug
    COMMAND echo "🔍 Debug: ccache directory contents:"
    COMMAND ls -la "$ENV{CCACHE_DIR}" || echo "ccache directory not accessible"
    COMMAND echo "🔍 Debug: ccache directory size:"
    COMMAND du -sh "$ENV{CCACHE_DIR}" || echo "ccache directory size unavailable"
    COMMENT "🔍 Debugging ccache directory contents and size"
    VERBATIM
  )
endif()
