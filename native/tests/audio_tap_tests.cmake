# Audio decoder tap (Input::audio, SSTV et al.) DSP-only tests, included
# from the host-only test block in native/CMakeLists.txt (see that file's
# `if(NOT ANDROID AND PROJECT_IS_TOP_LEVEL)` section, after enable_testing()).
# Modeled on sdrcore_wfm_stereo_dsp_test above it: links the receiver's own
# translation unit directly against the public sdrcore::dsp::Receiver
# interface, no ABI/sdrcore.cpp, no USB adapters, no Dart/FFI.
add_executable(sdrcore_audio_tap_test
    tests/audio_tap_test.cpp
    src/dsp/receiver.cpp)
target_include_directories(sdrcore_audio_tap_test PRIVATE include)
target_compile_features(sdrcore_audio_tap_test PRIVATE cxx_std_17)
target_link_libraries(sdrcore_audio_tap_test PRIVATE sdrcore_rds)
add_test(NAME sdrcore_audio_tap COMMAND sdrcore_audio_tap_test)
