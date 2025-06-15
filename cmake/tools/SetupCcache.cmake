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
  message(STATUS "Using ephemeral ccache directory: ${CCACHE_DIR_OVERRIDE}")
elseif(CI AND APPLE)
  # For CI on macOS, use build directory for reliable permissions
  set(MACOS_CCACHE_DIR ${BUILD_PATH}/cache/ccache)
  setenv(CCACHE_DIR ${MACOS_CCACHE_DIR})
  file(MAKE_DIRECTORY ${MACOS_CCACHE_DIR})
  message(STATUS "Using macOS CI ccache directory: ${MACOS_CCACHE_DIR}")
else()
  setenv(CCACHE_DIR ${CACHE_PATH}/ccache)
  file(MAKE_DIRECTORY ${CACHE_PATH}/ccache)
  message(STATUS "Using default ccache directory: ${CACHE_PATH}/ccache")
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
