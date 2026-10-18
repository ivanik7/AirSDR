# Run both builds on the same IQ vector and command sequence. No RF hardware.
execute_process(COMMAND "${ORIGINAL}" OUTPUT_VARIABLE original RESULT_VARIABLE original_rc)
execute_process(COMMAND "${PORT}" OUTPUT_VARIABLE port RESULT_VARIABLE port_rc)
if(NOT original_rc EQUAL 0 OR NOT port_rc EQUAL 0 OR NOT original STREQUAL port)
    message(FATAL_ERROR "SDR++ original/port command and IQ traces differ:\noriginal=${original}\nport=${port}")
endif()
message(STATUS "SDR++ original/port command and IQ traces match")
