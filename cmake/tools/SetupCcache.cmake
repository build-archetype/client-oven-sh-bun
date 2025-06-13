optionx(ENABLE_CCACHE BOOL "If ccache should be enabled" DEFAULT ON)

message(STATUS "=== CCACHE CONFIGURATION ===")
message(STATUS "ENABLE_CCACHE: ${ENABLE_CCACHE}")
message(STATUS "CACHE_STRATEGY: ${CACHE_STRATEGY}")

if(NOT ENABLE_CCACHE OR CACHE_STRATEGY STREQUAL "none")
  message(STATUS "Disabling ccache (ENABLE_CCACHE=${ENABLE_CCACHE}, CACHE_STRATEGY=${CACHE_STRATEGY})")
  setenv(CCACHE_DISABLE 1)
  return()
endif()

if (CI AND NOT APPLE)
  message(STATUS "Disabling ccache (CI=${CI}, APPLE=${APPLE})")
  setenv(CCACHE_DISABLE 1)
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
  message(STATUS "ccache not found, disabling")
  return()
endif()

message(STATUS "Found ccache: ${CCACHE_PROGRAM}")

# Set compiler launcher variables
set(CCACHE_ARGS CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER)
foreach(arg ${CCACHE_ARGS})
  setx(${arg} ${CCACHE_PROGRAM})
  list(APPEND CMAKE_ARGS -D${arg}=${${arg}})
endforeach()

# Set ccache environment variables
setenv(CCACHE_DIR ${CACHE_PATH}/ccache)
setenv(CCACHE_BASEDIR ${CWD})
setenv(CCACHE_NOHASHDIR 1)

if(CACHE_STRATEGY STREQUAL "read-only")
  setenv(CCACHE_READONLY 1)
  message(STATUS "Setting ccache to read-only mode")
elseif(CACHE_STRATEGY STREQUAL "write-only")
  setenv(CCACHE_RECACHE 1)
  message(STATUS "Setting ccache to write-only mode")
endif()

setenv(CCACHE_FILECLONE 1)
setenv(CCACHE_STATSLOG ${BUILD_PATH}/ccache.log)
setenv(CCACHE_LOGFILE ${BUILD_PATH}/ccache.log)
setenv(CCACHE_DEBUG 1)

# Add debug output for compilation commands
set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM} -v")
set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM} -v")

if(CI)
  # FIXME: Does not work on Ubuntu 18.04
  # setenv(CCACHE_SLOPPINESS "pch_defines,time_macros,locale,clang_index_store,gcno_cwd,include_file_ctime,include_file_mtime")
else()
  setenv(CCACHE_MAXSIZE 100G)
  setenv(CCACHE_SLOPPINESS "pch_defines,time_macros,locale,random_seed,clang_index_store,gcno_cwd")
endif()

message(STATUS "=== END CCACHE CONFIGURATION ===")

# Add a post-build command to check ccache stats
add_custom_command(
  TARGET upload-all-caches
  POST_BUILD
  COMMAND ${CCACHE_PROGRAM} -s
  COMMENT "Checking ccache statistics"
)
