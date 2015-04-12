# Copyright (c) 2013-2015, Ruslan Baratov
# All rights reserved.

cmake_minimum_required(VERSION 3.0) # sleep

include(CMakeParseArguments) # cmake_parse_arguments

include(hunter_find_stamps)
include(hunter_gate_settings)
include(hunter_internal_error)
include(hunter_print_cmd)
include(hunter_status_debug)
include(hunter_status_print)
include(hunter_test_string_not_empty)
include(hunter_user_error)

function(hunter_download)
  set(one PACKAGE_NAME PACKAGE_COMPONENT)

  cmake_parse_arguments(HUNTER "" "${one}" "" ${ARGV})
  # -> HUNTER_PACKAGE_NAME
  # -> HUNTER_PACKAGE_COMPONENT

  if(HUNTER_UNPARSED_ARGUMENTS)
    hunter_internal_error("Unparsed")
  endif()

  set(versions "[${HUNTER_${HUNTER_PACKAGE_NAME}_VERSIONS}]")
  hunter_status_debug(
      "${HUNTER_PACKAGE_NAME} versions available: ${versions}"
  )

  hunter_test_string_not_empty("${HUNTER_DOWNLOAD_SCHEME}")
  hunter_test_string_not_empty("${HUNTER_SELF}")

  hunter_test_string_not_empty("${HUNTER_INSTALL_PREFIX}")
  hunter_test_string_not_empty("${HUNTER_PACKAGE_NAME}")
  hunter_test_string_not_empty("${HUNTER_TOOLCHAIN_ID_PATH}")

  # Set <LIB>_ROOT variables
  set(h_name "${HUNTER_PACKAGE_NAME}") # Foo
  string(TOUPPER "${HUNTER_PACKAGE_NAME}" root_name) # FOO
  set(root_name "${root_name}_ROOT") # FOO_ROOT

  set(ver ${HUNTER_${h_name}_VERSION})
  set(HUNTER_PACKAGE_URL "${HUNTER_${h_name}_URL}")
  set(HUNTER_PACKAGE_SHA1 "${HUNTER_${h_name}_SHA1}")

  string(COMPARE EQUAL "${HUNTER_PACKAGE_SHA1}" "" version_not_found)
  if(version_not_found)
    hunter_user_error("Version not found: ${ver}. See 'hunter_config' command.")
  endif()

  hunter_test_string_not_empty("${HUNTER_PACKAGE_URL}")
  hunter_test_string_not_empty("${HUNTER_PACKAGE_SHA1}")

  hunter_make_directory(
      "${HUNTER_CACHED_ROOT}/_Base/Download/${HUNTER_PACKAGE_NAME}/${ver}"
      "${HUNTER_PACKAGE_SHA1}"
      HUNTER_PACKAGE_DOWNLOAD_DIR
  )

  if(NOT DEFINED HUNTER_DOWNLOAD_SCHEME_INSTALL)
    hunter_internal_error("HUNTER_DOWNLOAD_SCHEME_INSTALL not defined")
  endif()

  # Set:
  #   * HUNTER_PACKAGE_SOURCE_DIR
  #   * HUNTER_PACKAGE_DONE_STAMP
  #   * HUNTER_PACKAGE_BUILD_DIR
  #   * HUNTER_PACKAGE_HOME_DIR
  if(HUNTER_DOWNLOAD_SCHEME_INSTALL)
    set(${root_name} "${HUNTER_INSTALL_PREFIX}")
    set(HUNTER_PACKAGE_HOME_DIR "${HUNTER_TOOLCHAIN_ID_PATH}/Build")
    set(
        HUNTER_PACKAGE_HOME_DIR
        "${HUNTER_PACKAGE_HOME_DIR}/${HUNTER_PACKAGE_NAME}"
    )
    if(HUNTER_PACKAGE_COMPONENT)
      set(
          HUNTER_PACKAGE_HOME_DIR
          "${HUNTER_PACKAGE_HOME_DIR}/${HUNTER_PACKAGE_COMPONENT}"
      )
    endif()
    set(HUNTER_PACKAGE_DONE_STAMP "${HUNTER_PACKAGE_HOME_DIR}/DONE")
    set(HUNTER_PACKAGE_BUILD_DIR "${HUNTER_PACKAGE_HOME_DIR}/Build")
    set(HUNTER_PACKAGE_SOURCE_DIR "${HUNTER_PACKAGE_HOME_DIR}/Source")
    hunter_status_debug("Install to: ${HUNTER_INSTALL_PREFIX}")
  else()
    set(HUNTER_PACKAGE_SOURCE_DIR "${HUNTER_PACKAGE_DOWNLOAD_DIR}/Unpacked")
    set(${root_name} "${HUNTER_PACKAGE_SOURCE_DIR}")
    set(HUNTER_PACKAGE_DONE_STAMP "${HUNTER_PACKAGE_DOWNLOAD_DIR}/Stamp/DONE")
    set(HUNTER_PACKAGE_BUILD_DIR "${HUNTER_PACKAGE_DOWNLOAD_DIR}/Build")
    set(HUNTER_PACKAGE_HOME_DIR "${HUNTER_PACKAGE_DOWNLOAD_DIR}")
    hunter_status_debug("Unpack to: ${HUNTER_PACKAGE_SOURCE_DIR}")
  endif()

  set(${root_name} "${${root_name}}" PARENT_SCOPE)
  set(ENV{${root_name}} "${${root_name}}")
  hunter_status_print("${root_name}: ${${root_name}} (ver.: ${ver})")

  # temp toolchain file to set environment variables and include real toolchain
  set(HUNTER_DOWNLOAD_TOOLCHAIN "${HUNTER_PACKAGE_HOME_DIR}/toolchain.cmake")

  if(EXISTS "${HUNTER_PACKAGE_DONE_STAMP}")
    hunter_status_debug("Package already installed: ${HUNTER_PACKAGE_NAME}")
    if(HUNTER_PACKAGE_COMPONENT)
      hunter_status_debug("Component: ${HUNTER_PACKAGE_COMPONENT}")
    endif()
    return()
  endif()

  hunter_lock_directory("${HUNTER_PACKAGE_DOWNLOAD_DIR}")
  if(HUNTER_DOWNLOAD_SCHEME_INSTALL)
    hunter_lock_directory("${HUNTER_TOOLCHAIN_ID_PATH}")
  endif()

  # While locking other instance can finish package building
  if(EXISTS "${HUNTER_PACKAGE_DONE_STAMP}")
    hunter_status_debug("Package already installed: ${HUNTER_PACKAGE_NAME}")
    if(HUNTER_PACKAGE_COMPONENT)
      hunter_status_debug("Component: ${HUNTER_PACKAGE_COMPONENT}")
    endif()
    return()
  endif()

  file(REMOVE_RECURSE "${HUNTER_PACKAGE_BUILD_DIR}")
  file(REMOVE "${HUNTER_PACKAGE_HOME_DIR}/CMakeLists.txt")
  file(REMOVE "${HUNTER_DOWNLOAD_TOOLCHAIN}")

  # Forward Hunter cache variables
  hunter_gate_settings(gate_settings)

  # Do not lock hunter directory if package is internal (already locked)
  file(APPEND "${HUNTER_DOWNLOAD_TOOLCHAIN}" "set(HUNTER_SKIP_LOCK YES)\n")

  # support for toolchain file forwarding
  if(CMAKE_TOOLCHAIN_FILE)
    # Fix windows path
    get_filename_component(x "${CMAKE_TOOLCHAIN_FILE}" ABSOLUTE)
    file(APPEND "${HUNTER_DOWNLOAD_TOOLCHAIN}" "include(\"${x}\")\n")
  endif()

  set(var_name "")
  foreach(fwd ${HUNTER_${h_name}_CMAKE_ARGS})
    string(FIND "${fwd}" "=" _hunter_update_var)
    if(_hunter_update_var EQUAL -1)
      # There is no '=' symbol - appending mode
      if(NOT var_name)
        hunter_internal_error("var_name empty")
      endif()
      set(var_value "${fwd}")
      file(
          APPEND
          "${HUNTER_DOWNLOAD_TOOLCHAIN}"
          "set(\"${var_name}\" \"\${${var_name}}\" \"${var_value}\" CACHE INTERNAL \"\")\n"
      )
      hunter_status_debug("Add extra CMake args: ${var_name} += ${var_value}")
    else()
      # Format <name>=<value>
      string(REGEX REPLACE "=.*" "" var_name "${fwd}")
      string(REGEX REPLACE ".*=" "" var_value "${fwd}")
      file(
          APPEND
          "${HUNTER_DOWNLOAD_TOOLCHAIN}"
          "set(\"${var_name}\" \"${var_value}\" CACHE INTERNAL \"\")\n"
      )
      hunter_status_debug("Add extra CMake args: ${var_name} = ${var_value}")
    endif()
  endforeach()

  if(HUNTER_STATUS_DEBUG)
    set(verbose_makefile "-DCMAKE_VERBOSE_MAKEFILE=ON")
  else()
    set(verbose_makefile "")
  endif()

  if(NOT HUNTER_PACKAGE_URL)
    set(avail ${HUNTER_${h_name}_VERSIONS})
    hunter_internal_error(
        "${h_name} version(${ver}) not found. Available: [${avail}]"
    )
  endif()

  # print info before start generation/run
  hunter_status_debug("Add package: ${HUNTER_PACKAGE_NAME}")
  if(HUNTER_PACKAGE_COMPONENT)
    hunter_status_debug("Component: ${HUNTER_PACKAGE_COMPONENT}")
  endif()
  hunter_status_debug("Download scheme: ${HUNTER_DOWNLOAD_SCHEME}")
  hunter_status_debug("Url: ${HUNTER_PACKAGE_URL}")
  hunter_status_debug("SHA1: ${HUNTER_PACKAGE_SHA1}")

  set(
      download_scheme
      "${HUNTER_SELF}/cmake/schemes/${HUNTER_DOWNLOAD_SCHEME}.cmake.in"
  )
  if(NOT EXISTS "${download_scheme}")
    hunter_internal_error("Download scheme `${download_scheme}` not found")
  endif()

  configure_file(
      "${download_scheme}"
      "${HUNTER_PACKAGE_HOME_DIR}/CMakeLists.txt"
      @ONLY
  )

  set(build_message "Building ${HUNTER_PACKAGE_NAME}")
  if(HUNTER_PACKAGE_COMPONENT)
    set(
        build_message
        "${build_message} (component: ${HUNTER_PACKAGE_COMPONENT})"
    )
  endif()
  hunter_status_print("${build_message}")

  if(HUNTER_STATUS_DEBUG)
    set(logging_params "")
  elseif(HUNTER_STATUS_PRINT)
    set(logging_params "")
  else()
    set(logging_params "OUTPUT_QUIET")
  endif()

  set(
      cmd
      "${CMAKE_COMMAND}"
      "-H${HUNTER_PACKAGE_HOME_DIR}"
      "-B${HUNTER_PACKAGE_BUILD_DIR}"
      "-DCMAKE_TOOLCHAIN_FILE=${HUNTER_DOWNLOAD_TOOLCHAIN}"
      "-DHUNTER_STATUS_DEBUG=${HUNTER_STATUS_DEBUG}"
      "-G${CMAKE_GENERATOR}"
      ${gate_settings}
      ${verbose_makefile}
  )
  hunter_print_cmd("${HUNTER_PACKAGE_HOME_DIR}" "${cmd}")

  # Configure and build downloaded project
  execute_process(
      COMMAND ${cmd}
      WORKING_DIRECTORY "${HUNTER_PACKAGE_HOME_DIR}"
      RESULT_VARIABLE generate_result
      ${logging_params}
  )

  if(generate_result EQUAL 0)
    hunter_status_debug(
        "Configure step successful (dir: ${HUNTER_PACKAGE_HOME_DIR})"
    )
  else()
    hunter_fatal_error(
        "Configure step failed (dir: ${HUNTER_PACKAGE_HOME_DIR})"
        WIKI "error.external.build.failed"
    )
  endif()

  set(
      cmd
      "${CMAKE_COMMAND}"
      --build
      "${HUNTER_PACKAGE_BUILD_DIR}"
  )
  hunter_print_cmd("${HUNTER_PACKAGE_HOME_DIR}" "${cmd}")

  execute_process(
      COMMAND ${cmd}
      WORKING_DIRECTORY "${HUNTER_PACKAGE_HOME_DIR}"
      RESULT_VARIABLE build_result
      ${logging_params}
  )

  if(build_result EQUAL 0)
    hunter_status_print(
        "Build step successful (dir: ${HUNTER_PACKAGE_HOME_DIR})"
    )
  else()
    hunter_fatal_error(
        "Build step failed (dir: ${HUNTER_PACKAGE_HOME_DIR}"
        WIKI "error.external.build.failed"
    )
  endif()

  hunter_find_stamps("${HUNTER_PACKAGE_BUILD_DIR}")

  file(REMOVE_RECURSE "${HUNTER_PACKAGE_BUILD_DIR}")
  if(HUNTER_DOWNLOAD_SCHEME_INSTALL)
    # Unpacked directory not needed (save some disk space)
    file(REMOVE_RECURSE "${HUNTER_PACKAGE_SOURCE_DIR}")
  endif()

  file(REMOVE "${HUNTER_PACKAGE_HOME_DIR}/CMakeLists.txt")
  file(REMOVE "${HUNTER_DOWNLOAD_TOOLCHAIN}")

  file(WRITE "${HUNTER_PACKAGE_DONE_STAMP}" "")
endfunction()
