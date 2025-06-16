get_filename_component(SCRIPT_NAME ${CMAKE_CURRENT_LIST_FILE} NAME)
message(STATUS "Running script: ${SCRIPT_NAME}")

if(NOT DOWNLOAD_URL OR NOT DOWNLOAD_PATH)
  message(FATAL_ERROR "DOWNLOAD_URL and DOWNLOAD_PATH are required")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
  set(TMP_PATH $ENV{TEMP})
else()
  set(TMP_PATH $ENV{TMPDIR})
endif()

if(NOT TMP_PATH)
  set(TMP_PATH ${CMAKE_BINARY_DIR}/tmp)
endif()

string(REGEX REPLACE "/+$" "" TMP_PATH ${TMP_PATH})
string(REGEX REPLACE "[^a-zA-Z0-9]" "-" DOWNLOAD_ID ${DOWNLOAD_URL})
string(RANDOM LENGTH 8 RANDOM_ID)

set(DOWNLOAD_TMP_PATH ${TMP_PATH}/${DOWNLOAD_ID}-${RANDOM_ID})
set(DOWNLOAD_TMP_FILE ${DOWNLOAD_TMP_PATH}/tmp)

file(REMOVE_RECURSE ${DOWNLOAD_TMP_PATH})

if(DOWNLOAD_ACCEPT_HEADER)
  set(DOWNLOAD_ACCEPT_HEADER "Accept: ${DOWNLOAD_ACCEPT_HEADER}")
else()
  set(DOWNLOAD_ACCEPT_HEADER "Accept: */*")
endif()

foreach(i RANGE 10)
  set(DOWNLOAD_TMP_FILE_${i} ${DOWNLOAD_TMP_FILE}.${i})

  if(i EQUAL 0)
    message(STATUS "Downloading ${DOWNLOAD_URL}...")
  else()
    message(STATUS "Downloading ${DOWNLOAD_URL}... (retry ${i})")
  endif()
  
  file(DOWNLOAD
    ${DOWNLOAD_URL}
    ${DOWNLOAD_TMP_FILE_${i}}
    HTTPHEADER "User-Agent: cmake/${CMAKE_VERSION}"
    HTTPHEADER ${DOWNLOAD_ACCEPT_HEADER}
    STATUS DOWNLOAD_STATUS
    INACTIVITY_TIMEOUT 60
    TIMEOUT 180
    SHOW_PROGRESS
  )

  list(GET DOWNLOAD_STATUS 0 DOWNLOAD_STATUS_CODE)
  if(DOWNLOAD_STATUS_CODE EQUAL 0)
    if(NOT EXISTS ${DOWNLOAD_TMP_FILE_${i}})
      message(WARNING "Download failed: result is ok, but file does not exist: ${DOWNLOAD_TMP_FILE_${i}}")
      continue()
    endif()

    file(RENAME ${DOWNLOAD_TMP_FILE_${i}} ${DOWNLOAD_TMP_FILE})
    break()
  endif()

  list(GET DOWNLOAD_STATUS 1 DOWNLOAD_STATUS_TEXT)
  file(REMOVE ${DOWNLOAD_TMP_FILE_${i}})
  message(WARNING "Download failed: ${DOWNLOAD_STATUS_CODE} ${DOWNLOAD_STATUS_TEXT}")
endforeach()

if(NOT EXISTS ${DOWNLOAD_TMP_FILE})
  file(REMOVE_RECURSE ${DOWNLOAD_TMP_PATH})
  message(FATAL_ERROR "Download failed after too many attempts: ${DOWNLOAD_URL}")
endif()

get_filename_component(DOWNLOAD_FILENAME ${DOWNLOAD_URL} NAME)
if(DOWNLOAD_FILENAME MATCHES "\\.(zip|tar|gz|xz)$")
  message(STATUS "Extracting ${DOWNLOAD_FILENAME}...")

  set(DOWNLOAD_TMP_EXTRACT ${DOWNLOAD_TMP_PATH}/extract)
  file(ARCHIVE_EXTRACT
    INPUT ${DOWNLOAD_TMP_FILE}
    DESTINATION ${DOWNLOAD_TMP_EXTRACT}
    TOUCH
  )

  file(REMOVE ${DOWNLOAD_TMP_FILE})

  if(DOWNLOAD_FILTERS)
    list(TRANSFORM DOWNLOAD_FILTERS PREPEND ${DOWNLOAD_TMP_EXTRACT}/ OUTPUT_VARIABLE DOWNLOAD_GLOBS)
  else()
    set(DOWNLOAD_GLOBS ${DOWNLOAD_TMP_EXTRACT}/*)
  endif()

  file(GLOB DOWNLOAD_TMP_EXTRACT_PATHS LIST_DIRECTORIES ON ${DOWNLOAD_GLOBS})
  list(LENGTH DOWNLOAD_TMP_EXTRACT_PATHS DOWNLOAD_COUNT)

  if(DOWNLOAD_COUNT EQUAL 0)
    file(REMOVE_RECURSE ${DOWNLOAD_TMP_PATH})

    if(DOWNLOAD_FILTERS)
      message(FATAL_ERROR "Extract failed: No files found matching ${DOWNLOAD_FILTERS}")
    else()
      message(FATAL_ERROR "Extract failed: No files found")
    endif()
  endif()

  if(DOWNLOAD_FILTERS)
    set(DOWNLOAD_TMP_FILE ${DOWNLOAD_TMP_EXTRACT_PATHS})
  elseif(DOWNLOAD_COUNT EQUAL 1)
    list(GET DOWNLOAD_TMP_EXTRACT_PATHS 0 DOWNLOAD_TMP_FILE)
    get_filename_component(DOWNLOAD_FILENAME ${DOWNLOAD_TMP_FILE} NAME)
    message(STATUS "Hoisting ${DOWNLOAD_FILENAME}...")
  else()
    set(DOWNLOAD_TMP_FILE ${DOWNLOAD_TMP_EXTRACT})
  endif()
endif()

if(DOWNLOAD_FILTERS)
  foreach(file ${DOWNLOAD_TMP_FILE})
    # Check if we're copying to a Tart mounted directory (which has many filesystem restrictions)
    if(DOWNLOAD_PATH MATCHES "My Shared Files")
      # Use cmake -E copy for Tart mounted directories (more reliable than file() commands)
      message(STATUS "Using cmake -E copy for Tart mounted directory...")
      execute_process(
        COMMAND ${CMAKE_COMMAND} -E copy_directory ${file} ${DOWNLOAD_PATH}
        RESULT_VARIABLE COPY_RESULT
      )
      
      if(NOT COPY_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to copy ${file} to Tart mounted directory ${DOWNLOAD_PATH}")
      endif()
    else()
      # Use normal COPY for other destinations to preserve permissions
      file(COPY ${file} DESTINATION ${DOWNLOAD_PATH})
    endif()
    file(REMOVE_RECURSE ${file})
  endforeach()
else()
  file(REMOVE_RECURSE ${DOWNLOAD_PATH})
  get_filename_component(DOWNLOAD_PARENT_PATH ${DOWNLOAD_PATH} DIRECTORY)
  file(MAKE_DIRECTORY ${DOWNLOAD_PARENT_PATH})
  
  # Check if we're copying to a Tart mounted directory (which has many filesystem restrictions)
  if(DOWNLOAD_PATH MATCHES "My Shared Files")
    # Use cmake -E copy for Tart mounted directories (more reliable than file() commands)
    message(STATUS "Using cmake -E copy for Tart mounted directory...")
    
    # For Zig archives, use a more robust extraction method
    if(DOWNLOAD_FILENAME MATCHES "zig.*\\.zip$" OR DOWNLOAD_PATH MATCHES "/zig$")
      message(STATUS "Detected Zig archive - using robust extraction for mounted filesystem...")
      
      # Create target directory first
      file(MAKE_DIRECTORY ${DOWNLOAD_PATH})
      
      # Use rsync for more reliable deep copy (handles nested directories better)
      execute_process(
        COMMAND rsync -av "${DOWNLOAD_TMP_FILE}/" "${DOWNLOAD_PATH}/"
        RESULT_VARIABLE RSYNC_RESULT
        OUTPUT_VARIABLE RSYNC_OUTPUT
        ERROR_VARIABLE RSYNC_ERROR
      )
      
      if(NOT RSYNC_RESULT EQUAL 0)
        message(WARNING "rsync failed (result: ${RSYNC_RESULT})")
        message(WARNING "rsync error: ${RSYNC_ERROR}")
        
        # Fallback: use tar for complete archive extraction
        message(STATUS "Attempting tar-based extraction...")
        execute_process(
          COMMAND /bin/sh -c "cd '${DOWNLOAD_TMP_FILE}' && tar -cf - . | (cd '${DOWNLOAD_PATH}' && tar -xf -)"
          RESULT_VARIABLE TAR_RESULT
          OUTPUT_VARIABLE TAR_OUTPUT  
          ERROR_VARIABLE TAR_ERROR
        )
        
        if(NOT TAR_RESULT EQUAL 0)
          message(FATAL_ERROR "All extraction methods failed for Zig archive to Tart mounted directory")
        else()
          message(STATUS "tar-based extraction successful")
        endif()
      else()
        message(STATUS "rsync extraction successful")
      endif()
    else()
      # For non-Zig archives, use existing method
      # First attempt with cmake -E copy_directory
      execute_process(
        COMMAND ${CMAKE_COMMAND} -E copy_directory ${DOWNLOAD_TMP_FILE} ${DOWNLOAD_PATH}
        RESULT_VARIABLE COPY_RESULT
        OUTPUT_VARIABLE COPY_OUTPUT
        ERROR_VARIABLE COPY_ERROR
      )
      
      if(NOT COPY_RESULT EQUAL 0)
        message(WARNING "cmake -E copy_directory failed (result: ${COPY_RESULT})")
        message(WARNING "Output: ${COPY_OUTPUT}")
        message(WARNING "Error: ${COPY_ERROR}")
        
        # Fallback: try tar-based copy with proper path escaping
        message(STATUS "Attempting fallback copy method...")
        execute_process(
          COMMAND /bin/sh -c "cd '${DOWNLOAD_TMP_FILE}' && tar -cf - . | (cd '${DOWNLOAD_PATH}' && tar -xf -)"
          RESULT_VARIABLE TAR_RESULT
          OUTPUT_VARIABLE TAR_OUTPUT  
          ERROR_VARIABLE TAR_ERROR
        )
        
        if(NOT TAR_RESULT EQUAL 0)
          message(WARNING "Tar-based copy also failed (result: ${TAR_RESULT})")
          message(WARNING "Tar output: ${TAR_OUTPUT}")
          message(WARNING "Tar error: ${TAR_ERROR}")
          message(FATAL_ERROR "Failed to copy ${DOWNLOAD_TMP_FILE} to Tart mounted directory ${DOWNLOAD_PATH} - all copy methods failed")
        endif()
      else()
        message(STATUS "cmake -E copy_directory successful")
      endif()
    endif()
  else()
    # Use normal COPY for other destinations to preserve permissions
    file(COPY ${DOWNLOAD_TMP_FILE} DESTINATION ${DOWNLOAD_PARENT_PATH})
    get_filename_component(DOWNLOAD_TMP_NAME ${DOWNLOAD_TMP_FILE} NAME)
    set(COPIED_PATH ${DOWNLOAD_PARENT_PATH}/${DOWNLOAD_TMP_NAME})
    if(NOT ${COPIED_PATH} STREQUAL ${DOWNLOAD_PATH})
      file(RENAME ${COPIED_PATH} ${DOWNLOAD_PATH})
    endif()
  endif()
endif()

file(REMOVE_RECURSE ${DOWNLOAD_TMP_PATH})
message(STATUS "Saved ${DOWNLOAD_PATH}")
