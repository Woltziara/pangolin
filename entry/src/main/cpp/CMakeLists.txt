cmake_minimum_required(VERSION 3.5.0)
project(heyvpn)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(HEYVPN_PREBUILT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/arm64-v8a)

add_library(heyvpn SHARED napi_init.cpp xray_start_lifecycle.cpp app_flow_router.cpp)
set_target_properties(heyvpn PROPERTIES C_VISIBILITY_PRESET default CXX_VISIBILITY_PRESET default)
target_include_directories(heyvpn PRIVATE "${HEYVPN_PREBUILT_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(heyvpn PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libdl.so)

# Production HAP only ships the R1 cores: libxray.so + libhevsocks5tun.so.
# Missing cores are a configuration error, never a silently incomplete HAP.
add_custom_target(copy_prebuilt_libs ALL)
add_dependencies(copy_prebuilt_libs heyvpn)
foreach(PREBUILT_LIB libxray.so libhevsocks5tun.so)
    if(EXISTS "${HEYVPN_PREBUILT_DIR}/${PREBUILT_LIB}")
        add_custom_command(TARGET copy_prebuilt_libs POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${HEYVPN_PREBUILT_DIR}/${PREBUILT_LIB}"
            "$<TARGET_FILE_DIR:heyvpn>/${PREBUILT_LIB}")
    else()
        message(FATAL_ERROR "Missing ${PREBUILT_LIB}. Run scripts/build.sh first.")
    endif()
endforeach()
