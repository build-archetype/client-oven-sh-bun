optionx(BUILDKITE_CACHE_RESTORE BOOL "If the build should restore cache from Buildkite artifacts" DEFAULT OFF)
optionx(BUILDKITE_CACHE_SAVE BOOL "If the build should save cache to Buildkite artifacts" DEFAULT OFF)

# Only apply to macOS CI builds
if(NOT BUILDKITE OR NOT APPLE)
  return()
endif()

# Generate cache key based on platform
if(ENABLE_BASELINE)
  set(DEFAULT_CACHE_KEY cache-${OS}-${ARCH}-baseline)
else()
  set(DEFAULT_CACHE_KEY cache-${OS}-${ARCH})
endif()

optionx(BUILDKITE_CACHE_KEY STRING "The cache key to use for artifacts" DEFAULT ${DEFAULT_CACHE_KEY})

# Set ephemeral cache directories - use build directory for reliable permissions
if(BUILDKITE_CACHE_RESTORE OR BUILDKITE_CACHE_SAVE)
  set(EPHEMERAL_CCACHE_DIR ${BUILD_PATH}/cache-ephemeral/ccache)
  set(EPHEMERAL_ZIG_DIR ${BUILD_PATH}/cache-ephemeral/zig)
  
  # Create directories with proper permissions immediately
  file(MAKE_DIRECTORY ${EPHEMERAL_CCACHE_DIR})
  file(MAKE_DIRECTORY ${EPHEMERAL_ZIG_DIR}/local)
  file(MAKE_DIRECTORY ${EPHEMERAL_ZIG_DIR}/global)
  
  # Ensure proper permissions (readable, writable, executable for owner)
  execute_process(
    COMMAND chmod -R 755 ${BUILD_PATH}/cache-ephemeral
    OUTPUT_QUIET
    ERROR_QUIET
  )
  
  # Override cache directories in other modules
  set(CCACHE_DIR_OVERRIDE ${EPHEMERAL_CCACHE_DIR} CACHE INTERNAL "")
  set(ZIG_LOCAL_CACHE_DIR_OVERRIDE ${EPHEMERAL_ZIG_DIR}/local CACHE INTERNAL "")
  set(ZIG_GLOBAL_CACHE_DIR_OVERRIDE ${EPHEMERAL_ZIG_DIR}/global CACHE INTERNAL "")
  
  message(STATUS "Ephemeral cache directories created:")
  message(STATUS "  CCACHE: ${EPHEMERAL_CCACHE_DIR}")
  message(STATUS "  ZIG: ${EPHEMERAL_ZIG_DIR}")
endif()

# Cache restore target (runs before build)
if(BUILDKITE_CACHE_RESTORE)
  add_custom_target(cache-restore
    COMMAND ${CMAKE_COMMAND}
      -DBUILDKITE_CACHE_KEY=${BUILDKITE_CACHE_KEY}
      -DCCACHE_CACHE_DIR=${EPHEMERAL_CCACHE_DIR}
      -DZIG_CACHE_DIR=${EPHEMERAL_ZIG_DIR}
      -DBUILD_PATH=${BUILD_PATH}
      -DACTION=restore
      -P ${CMAKE_SOURCE_DIR}/cmake/scripts/ManageBuildkiteCache.cmake
    COMMENT "Restoring build caches from Buildkite artifacts"
    VERBATIM
  )
endif()

# Cache save target (runs after build)
if(BUILDKITE_CACHE_SAVE)
  add_custom_target(cache-save
    COMMAND ${CMAKE_COMMAND}
      -DBUILDKITE_CACHE_KEY=${BUILDKITE_CACHE_KEY}
      -DCCACHE_CACHE_DIR=${EPHEMERAL_CCACHE_DIR}
      -DZIG_CACHE_DIR=${EPHEMERAL_ZIG_DIR}
      -DBUILD_PATH=${BUILD_PATH}
      -DACTION=save
      -P ${CMAKE_SOURCE_DIR}/cmake/scripts/ManageBuildkiteCache.cmake
    COMMENT "Saving build caches to Buildkite artifacts"
    VERBATIM
  )
endif() 