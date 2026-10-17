# csdr-plus SSTV backend tests (adapter + vendored upstream decoder + the
# receiver's 24 kHz audio tap), included from the host-only test block in
# native/CMakeLists.txt. Signals come from tests/sstv_test_encoder.hpp.
add_executable(sdrcore_sstv_test
    tests/sstv_test.cpp
    src/decoder/sstv.cpp
    src/dsp/receiver.cpp)
target_include_directories(sdrcore_sstv_test PRIVATE include third_party)
target_compile_features(sdrcore_sstv_test PRIVATE cxx_std_17)
# The decoder's per-pixel FFT work dominates; keep the long images fast in
# Debug test builds too.
target_compile_options(sdrcore_sstv_test PRIVATE -O2)
target_link_libraries(sdrcore_sstv_test PRIVATE sdrcore_csdr_sstv sdrcore_rds)
add_test(NAME sdrcore_sstv COMMAND sdrcore_sstv_test)
set_tests_properties(sdrcore_sstv PROPERTIES TIMEOUT 900)

# Host-only replay tool for the OpenWebRX+ oracle comparison
# (tool/sstv_oracle/compare.py); not a CTest test and never in the app.
add_executable(sdrcore_sstv_replay
    tests/sstv_replay.cpp
    src/decoder/sstv.cpp
    src/dsp/receiver.cpp)
target_include_directories(sdrcore_sstv_replay PRIVATE include third_party)
target_compile_features(sdrcore_sstv_replay PRIVATE cxx_std_17)
target_compile_options(sdrcore_sstv_replay PRIVATE -O2)
target_link_libraries(sdrcore_sstv_replay PRIVATE sdrcore_csdr_sstv sdrcore_rds)
