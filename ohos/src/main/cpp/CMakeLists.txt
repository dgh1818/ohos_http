cmake_minimum_required(VERSION 3.5)

project(ohos_http_ffi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED DART_API_DL_ROOT OR DART_API_DL_ROOT STREQUAL "")
    message(FATAL_ERROR "DART_API_DL_ROOT must point to the directory containing dart_api_dl.h and dart_api_dl.c.")
endif()

if(NOT EXISTS "${DART_API_DL_ROOT}/dart_api_dl.h" OR NOT EXISTS "${DART_API_DL_ROOT}/dart_api_dl.c")
    message(FATAL_ERROR "DART_API_DL_ROOT is missing dart_api_dl.h or dart_api_dl.c: ${DART_API_DL_ROOT}")
endif()

if(NOT DEFINED OHOS_HTTP_CURL_INCLUDE_DIR OR OHOS_HTTP_CURL_INCLUDE_DIR STREQUAL "")
    set(OHOS_HTTP_CURL_INCLUDE_DIR "")
endif()

function(immich_dedupe_linker_flags cache_var cache_doc)
    if(NOT DEFINED ${cache_var})
        return()
    endif()

    set(_raw_flags "${${cache_var}}")
    if(_raw_flags STREQUAL "")
        return()
    endif()

    separate_arguments(_flag_list NATIVE_COMMAND "${_raw_flags}")
    set(_deduped_flags "")
    foreach(_flag IN LISTS _flag_list)
        if(NOT _flag IN_LIST _deduped_flags)
            list(APPEND _deduped_flags "${_flag}")
        endif()
    endforeach()

    string(REPLACE ";" " " _joined_flags "${_deduped_flags}")
    if(NOT _joined_flags STREQUAL _raw_flags)
        set(${cache_var} "${_joined_flags}" PARENT_SCOPE)
        set(${cache_var} "${_joined_flags}" CACHE STRING "${cache_doc}" FORCE)
    endif()
endfunction()

# DevEco's OHOS toolchain can append the same linker flags repeatedly
# during configure, which breaks the Windows linker invocation length.
immich_dedupe_linker_flags(CMAKE_SHARED_LINKER_FLAGS "Global shared linker flags")
immich_dedupe_linker_flags(CMAKE_MODULE_LINKER_FLAGS "Global module linker flags")
immich_dedupe_linker_flags(CMAKE_EXE_LINKER_FLAGS "Global executable linker flags")

add_library(ohos_http_ffi SHARED
    ${DART_API_DL_ROOT}/dart_api_dl.c
    ohos_http_ffi.cpp
)

set(OHOS_HTTP_LIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}")
set(OHOS_HTTP_LIBCURL "${OHOS_HTTP_LIBS_DIR}/libcurl.so")

if(EXISTS "${OHOS_HTTP_LIBCURL}")
    target_compile_definitions(ohos_http_ffi PRIVATE IMMICH_OHOS_HAS_LIBCURL=1)
endif()

target_include_directories(ohos_http_ffi PRIVATE
    "${DART_API_DL_ROOT}"
)

if(NOT OHOS_HTTP_CURL_INCLUDE_DIR STREQUAL "")
    target_include_directories(ohos_http_ffi PRIVATE
        "${OHOS_HTTP_CURL_INCLUDE_DIR}"
    )
endif()

# N-API (ArkTS) bridge library
target_link_libraries(ohos_http_ffi PUBLIC
    ace_napi.z
)

if(EXISTS "${OHOS_HTTP_LIBCURL}")
    target_link_libraries(ohos_http_ffi PRIVATE
        "${OHOS_HTTP_LIBCURL}"
    )
endif()