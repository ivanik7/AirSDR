# Source-built, pinned audio codecs. Include from native/CMakeLists.txt after
# add_subdirectory(third_party); no global package discovery or binary fetches.
set(SDRCORE_CODEC_ROOT "${CMAKE_CURRENT_LIST_DIR}")

add_library(sdrcore_ogg STATIC
    ${SDRCORE_CODEC_ROOT}/ogg/src/bitwise.c
    ${SDRCORE_CODEC_ROOT}/ogg/src/framing.c)
target_include_directories(sdrcore_ogg PUBLIC ${SDRCORE_CODEC_ROOT}/ogg/include)
set_target_properties(sdrcore_ogg PROPERTIES POSITION_INDEPENDENT_CODE ON C_STANDARD 99)

# Build the portable libFLAC C implementation. The intrinsic translation units
# are deliberately omitted; FLAC__NO_ASM selects the upstream scalar fallback.
set(_flac_src ${SDRCORE_CODEC_ROOT}/flac/src/libFLAC)
set(_flac_files
    bitmath bitreader bitwriter cpu crc fixed float format lpc md5 memory
    metadata_iterators metadata_object stream_decoder stream_encoder
    stream_encoder_framing window)
set(_flac_sources)
foreach(_name IN LISTS _flac_files)
    list(APPEND _flac_sources ${_flac_src}/${_name}.c)
endforeach()
add_library(sdrcore_flac STATIC ${_flac_sources})
target_include_directories(sdrcore_flac PUBLIC ${SDRCORE_CODEC_ROOT}/flac/include
    PRIVATE ${_flac_src}/include)
target_compile_definitions(sdrcore_flac PRIVATE FLAC__NO_ASM HAVE_LROUND HAVE_STDINT_H FLAC__HAS_OGG=0 PACKAGE_VERSION="1.4.3" PUBLIC FLAC__NO_DLL)
# llvm-mingw UCRT declares fseeko/ftello itself. Without HAVE_FSEEKO,
# libFLAC aliases them before stdio.h is included and conflicts with its
# native fseeko64/ftello64 declarations.
if(MINGW)
    target_compile_definitions(sdrcore_flac PRIVATE HAVE_FSEEKO)
endif()
set_target_properties(sdrcore_flac PROPERTIES POSITION_INDEPENDENT_CODE ON C_STANDARD 99)
if(NOT WIN32)
    target_link_libraries(sdrcore_flac PUBLIC m)
endif()

# LAME's libmp3lame Makefile.am source set, with its optional MP3 decoder off.
set(_lame_src ${SDRCORE_CODEC_ROOT}/lame/libmp3lame)
set(_lame_files VbrTag bitstream encoder fft gain_analysis id3tag lame newmdct
    presets psymodel quantize quantize_pvt reservoir set_get tables takehiro
    util vbrquantize version mpglib_interface)
set(_lame_sources)
foreach(_name IN LISTS _lame_files)
    list(APPEND _lame_sources ${_lame_src}/${_name}.c)
endforeach()
add_library(sdrcore_lame STATIC ${_lame_sources})
# Upstream's tarball keeps lame.h directly in include/; preserve both the
# upstream spelling <lame.h> and installed-package spelling <lame/lame.h>.
set(_codec_headers ${CMAKE_CURRENT_BINARY_DIR}/sdrcore_codec_headers)
file(MAKE_DIRECTORY "${_codec_headers}/lame" "${_codec_headers}/opus")
configure_file(${SDRCORE_CODEC_ROOT}/lame/include/lame.h
    ${_codec_headers}/lame/lame.h COPYONLY)
target_include_directories(sdrcore_lame PUBLIC ${SDRCORE_CODEC_ROOT}/lame/include
    ${_codec_headers}
    PRIVATE ${_lame_src} ${SDRCORE_CODEC_ROOT}/lame/mpglib)
target_compile_definitions(sdrcore_lame PRIVATE HAVE_CONFIG_H)
# Explicit portable configuration, independent of a build-host's autotools.
target_include_directories(sdrcore_lame PRIVATE ${SDRCORE_CODEC_ROOT}/lame/sdrcore_config)
set_target_properties(sdrcore_lame PROPERTIES POSITION_INDEPENDENT_CODE ON C_STANDARD 99)
if(NOT WIN32)
    target_link_libraries(sdrcore_lame PUBLIC m)
endif()

# Read upstream's authoritative Makefile source lists. No generated sources,
# DNN extensions, architecture-specific intrinsics, or runtime CPU probing.
set(_opus ${SDRCORE_CODEC_ROOT}/opus)
function(_sdrcore_opus_sources result mk group)
    file(STRINGS "${_opus}/${mk}" _lines)
    set(_sources)
    foreach(_line IN LISTS _lines)
        # file(STRINGS) joins Makefile backslash continuations with semicolons.
        if(_line MATCHES "^${group} *=")
            string(REGEX MATCHALL "[A-Za-z0-9_./-]+\\.c" _files "${_line}")
            foreach(_file IN LISTS _files)
                list(APPEND _sources "${_opus}/${_file}")
            endforeach()
        endif()
    endforeach()
    if(NOT _sources)
        message(FATAL_ERROR "Missing Opus upstream source group ${group} in ${mk}")
    endif()
    set(${result} ${_sources} PARENT_SCOPE)
endfunction()
_sdrcore_opus_sources(_opus_base opus_sources.mk OPUS_SOURCES)
_sdrcore_opus_sources(_opus_float opus_sources.mk OPUS_SOURCES_FLOAT)
_sdrcore_opus_sources(_silk_base silk_sources.mk SILK_SOURCES)
_sdrcore_opus_sources(_silk_float silk_sources.mk SILK_SOURCES_FLOAT)
_sdrcore_opus_sources(_celt celt_sources.mk CELT_SOURCES)
add_library(sdrcore_opus STATIC ${_opus_base} ${_opus_float} ${_silk_base}
    ${_silk_float} ${_celt})
# The release tarball lays public headers directly under include/ whereas
# consumers conventionally use <opus/opus.h>; expose both forms.
file(GLOB _opus_public_headers "${_opus}/include/*.h")
file(COPY ${_opus_public_headers} DESTINATION "${_codec_headers}/opus")
target_include_directories(sdrcore_opus PUBLIC ${_opus}/include ${_codec_headers}
    PRIVATE ${_opus} ${_opus}/src ${_opus}/celt ${_opus}/silk
        ${_opus}/silk/float ${_opus}/silk/fixed)
target_compile_definitions(sdrcore_opus PRIVATE OPUS_BUILD VAR_ARRAYS)
set_target_properties(sdrcore_opus PROPERTIES POSITION_INDEPENDENT_CODE ON C_STANDARD 99)
target_link_libraries(sdrcore_opus PUBLIC sdrcore_ogg)
if(NOT WIN32)
    target_link_libraries(sdrcore_opus PUBLIC m)
endif()
