cmake_minimum_required(VERSION 3.20)

# Validate required parameters
if(NOT DEFINED ACTION)
  message(FATAL_ERROR "ACTION must be defined (restore or save)")
endif()

if(NOT DEFINED BUILDKITE_CACHE_KEY)
  message(FATAL_ERROR "BUILDKITE_CACHE_KEY must be defined")
endif()

if(NOT DEFINED BUILD_PATH)
  message(FATAL_ERROR "BUILD_PATH must be defined")
endif()

if(NOT DEFINED CCACHE_CACHE_DIR)
  set(CCACHE_CACHE_DIR "${BUILD_PATH}/cache-ephemeral/ccache")
endif()

if(NOT DEFINED ZIG_CACHE_DIR)
  set(ZIG_CACHE_DIR "${BUILD_PATH}/cache-ephemeral/zig")
endif()

# Find required tools
find_program(BUILDKITE_AGENT buildkite-agent REQUIRED)
find_program(TAR tar REQUIRED)
find_program(ZSTD zstd REQUIRED)

# Helper function to ensure directory permissions
function(ensure_cache_permissions CACHE_DIR)
  if(EXISTS ${CACHE_DIR})
    execute_process(
      COMMAND chmod -R 755 ${CACHE_DIR}
      RESULT_VARIABLE CHMOD_RESULT
      OUTPUT_QUIET
      ERROR_QUIET
    )
    if(NOT CHMOD_RESULT EQUAL 0)
      message(WARNING "Failed to set permissions on ${CACHE_DIR}")
    endif()
  endif()
endfunction()

# Helper function to test write permissions
function(test_write_permissions CACHE_DIR SUCCESS_VAR)
  set(${SUCCESS_VAR} FALSE PARENT_SCOPE)
  
  # Try to create a test file
  set(TEST_FILE "${CACHE_DIR}/.write_test")
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E touch ${TEST_FILE}
    RESULT_VARIABLE TOUCH_RESULT
    OUTPUT_QUIET
    ERROR_QUIET
  )
  
  if(TOUCH_RESULT EQUAL 0 AND EXISTS ${TEST_FILE})
    # Try to write to the test file
    execute_process(
      COMMAND ${CMAKE_COMMAND} -E echo "test" 
      OUTPUT_FILE ${TEST_FILE}
      RESULT_VARIABLE WRITE_RESULT
      ERROR_QUIET
    )
    
    if(WRITE_RESULT EQUAL 0)
      # Clean up test file
      file(REMOVE ${TEST_FILE})
      set(${SUCCESS_VAR} TRUE PARENT_SCOPE)
    else()
      message(WARNING "Cannot write to cache directory: ${CACHE_DIR}")
      file(REMOVE ${TEST_FILE})
    endif()
  else()
    message(WARNING "Cannot create files in cache directory: ${CACHE_DIR}")
  endif()
endfunction()

function(restore_cache CACHE_TYPE CACHE_DIR)
  set(CACHE_FILE "${CACHE_TYPE}-${BUILDKITE_CACHE_KEY}.tar.zst")
  
  message(STATUS "Attempting to restore ${CACHE_TYPE} cache...")
  
  # Ensure cache directory exists with proper permissions
  file(MAKE_DIRECTORY ${CACHE_DIR})
  ensure_cache_permissions(${CACHE_DIR})
  
  # Test write permissions
  test_write_permissions(${CACHE_DIR} CAN_WRITE)
  if(NOT CAN_WRITE)
    message(WARNING "Cannot write to ${CACHE_TYPE} cache directory: ${CACHE_DIR}")
    message(WARNING "Cache restoration will be skipped for ${CACHE_TYPE}")
    return()
  endif()
  
  message(STATUS "Cache directory permissions verified: ${CACHE_DIR}")
  
  # Use existing Buildkite logic to find last successful build
  execute_process(
    COMMAND ${BUILDKITE_AGENT} artifact download ${CACHE_FILE} .
      --step "*cache-save*"
    WORKING_DIRECTORY ${BUILD_PATH}
    RESULT_VARIABLE DOWNLOAD_RESULT
    OUTPUT_QUIET
    ERROR_QUIET
  )
  
  if(DOWNLOAD_RESULT EQUAL 0 AND EXISTS "${BUILD_PATH}/${CACHE_FILE}")
    message(STATUS "Found ${CACHE_TYPE} cache artifact, extracting...")
    
    # Extract the cache directly to the cache directory
    get_filename_component(CACHE_PARENT_DIR ${CACHE_DIR} DIRECTORY)
    execute_process(
      COMMAND ${ZSTD} -d -c ${BUILD_PATH}/${CACHE_FILE}
      COMMAND ${TAR} xf - -C ${CACHE_PARENT_DIR}
      RESULT_VARIABLE EXTRACT_RESULT
      OUTPUT_QUIET
      ERROR_QUIET
    )
    
    # Clean up downloaded file
    file(REMOVE ${BUILD_PATH}/${CACHE_FILE})
    
    if(EXTRACT_RESULT EQUAL 0)
      # Ensure proper permissions after extraction
      ensure_cache_permissions(${CACHE_DIR})
      
      # Verify cache directory has content
      file(GLOB CACHE_CONTENTS "${CACHE_DIR}/*")
      if(CACHE_CONTENTS)
        message(STATUS "✅ ${CACHE_TYPE} cache restored successfully")
        
        # Initialize ccache if needed
        if(CACHE_TYPE STREQUAL "ccache")
          find_program(CCACHE ccache)
          if(CCACHE)
            execute_process(
              COMMAND ${CCACHE} -M 20G
              RESULT_VARIABLE CCACHE_RESULT
              OUTPUT_QUIET
              ERROR_QUIET
            )
          endif()
        endif()
      else()
        message(STATUS "⚠️ ${CACHE_TYPE} cache was empty")
        file(REMOVE_RECURSE ${CACHE_DIR})
        file(MAKE_DIRECTORY ${CACHE_DIR})
        ensure_cache_permissions(${CACHE_DIR})
      endif()
    else()
      message(STATUS "❌ Failed to extract ${CACHE_TYPE} cache")
      file(REMOVE_RECURSE ${CACHE_DIR})
      file(MAKE_DIRECTORY ${CACHE_DIR})
      ensure_cache_permissions(${CACHE_DIR})
    endif()
  else()
    message(STATUS "ℹ️ No ${CACHE_TYPE} cache found, starting fresh")
    file(MAKE_DIRECTORY ${CACHE_DIR})
    ensure_cache_permissions(${CACHE_DIR})
  endif()
endfunction()

function(save_cache CACHE_TYPE CACHE_DIR)
  if(NOT EXISTS ${CACHE_DIR})
    message(STATUS "⚠️ ${CACHE_TYPE} cache directory doesn't exist, skipping")
    return()
  endif()
  
  # Test write permissions
  test_write_permissions(${CACHE_DIR} CAN_WRITE)
  if(NOT CAN_WRITE)
    message(WARNING "Cannot write to ${CACHE_TYPE} cache directory: ${CACHE_DIR}")
    message(WARNING "Cache saving will be skipped for ${CACHE_TYPE}")
    return()
  endif()
  
  # Check if cache has content
  file(GLOB CACHE_CONTENTS "${CACHE_DIR}/*")
  if(NOT CACHE_CONTENTS)
    message(STATUS "ℹ️ ${CACHE_TYPE} cache is empty, skipping")
    return()
  endif()
  
  message(STATUS "📦 Saving ${CACHE_TYPE} cache...")
  message(STATUS "Cache directory verified: ${CACHE_DIR}")
  
  set(CACHE_FILE "${CACHE_TYPE}-${BUILDKITE_CACHE_KEY}.tar.zst")
  set(CACHE_FILE_PATH "${BUILD_PATH}/${CACHE_FILE}")
  
  # Clean up ccache before saving
  if(CACHE_TYPE STREQUAL "ccache")
    find_program(CCACHE ccache)
    if(CCACHE)
      execute_process(
        COMMAND ${CCACHE} -c
        OUTPUT_QUIET
        ERROR_QUIET
      )
    endif()
    
    # Remove temporary files
    file(GLOB_RECURSE TMP_FILES "${CACHE_DIR}/*.tmp.*")
    if(TMP_FILES)
      file(REMOVE ${TMP_FILES})
    endif()
  endif()
  
  # Create compressed archive - use relative path from cache parent directory
  get_filename_component(CACHE_PARENT_DIR ${CACHE_DIR} DIRECTORY)
  get_filename_component(CACHE_DIR_NAME ${CACHE_DIR} NAME)
  
  execute_process(
    COMMAND ${TAR} cf - ${CACHE_DIR_NAME}
    COMMAND ${ZSTD} -c
    WORKING_DIRECTORY ${CACHE_PARENT_DIR}
    OUTPUT_FILE ${CACHE_FILE_PATH}
    RESULT_VARIABLE ARCHIVE_RESULT
  )
  
  if(ARCHIVE_RESULT EQUAL 0 AND EXISTS ${CACHE_FILE_PATH})
    # Upload as Buildkite artifact
    execute_process(
      COMMAND ${BUILDKITE_AGENT} artifact upload ${CACHE_FILE}
      WORKING_DIRECTORY ${BUILD_PATH}
      RESULT_VARIABLE UPLOAD_RESULT
    )
    
    if(UPLOAD_RESULT EQUAL 0)
      message(STATUS "✅ ${CACHE_TYPE} cache saved successfully")
      
      # Show file size
      file(SIZE ${CACHE_FILE_PATH} CACHE_SIZE)
      math(EXPR CACHE_SIZE_MB "${CACHE_SIZE} / 1048576")
      message(STATUS "📊 ${CACHE_TYPE} cache size: ${CACHE_SIZE_MB} MB")
    else()
      message(STATUS "❌ Failed to upload ${CACHE_TYPE} cache")
    endif()
    
    # Clean up local file
    file(REMOVE ${CACHE_FILE_PATH})
  else()
    message(STATUS "❌ Failed to create ${CACHE_TYPE} cache archive")
  endif()
endfunction()

# Execute the action
if(ACTION STREQUAL "restore")
  message(STATUS "🔄 Restoring caches for ${BUILDKITE_CACHE_KEY}...")
  restore_cache("ccache" ${CCACHE_CACHE_DIR})
  restore_cache("zig" ${ZIG_CACHE_DIR})
  message(STATUS "✅ Cache restoration completed")
  
elseif(ACTION STREQUAL "save")
  message(STATUS "💾 Saving caches for ${BUILDKITE_CACHE_KEY}...")
  save_cache("ccache" ${CCACHE_CACHE_DIR})
  save_cache("zig" ${ZIG_CACHE_DIR})
  message(STATUS "✅ Cache saving completed")
  
else()
  message(FATAL_ERROR "Unknown ACTION: ${ACTION}")
endif() 