
add_library(munit "${CMAKE_CURRENT_SOURCE_DIR}/munit/munit.c")
target_include_directories(munit PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/munit")

# MinGW's tmpfile() fails in some Windows/MSYS environments. MUnit uses it
# only to buffer test stderr, so disable that optional capture on Windows.
if(WIN32)
	target_compile_definitions(munit PRIVATE MUNIT_NO_BUFFER)
endif()

set(CHIAKI_UNIT_SOURCES
				main.c
				http.c
				rpcrypt.c
				gkcrypt.c
				takion.c
				seqnum.c
				keystate.c
				reorderqueue.c
				fec.c
				test_log.c
				test_log.h
				bitstream.c
				regist.c)

if(NOT CHIAKI_LIB_ENABLE_MBEDTLS)
	list(APPEND CHIAKI_UNIT_SOURCES aia.c)
endif()

if(CHIAKI_ENABLE_FFMPEG_DECODER)
	list(APPEND CHIAKI_UNIT_SOURCES ffmpegdecoder.c)
endif()

add_executable(chiaki-unit ${CHIAKI_UNIT_SOURCES})
add_test(NAME unit COMMAND chiaki-unit)

target_link_libraries(chiaki-unit chiaki-lib munit)

if(CHIAKI_ENABLE_FFMPEG_DECODER)
	target_link_libraries(chiaki-unit FFMPEG::avcodec FFMPEG::avutil)
endif()

# O conversor manipula credenciais: entrada inválida não pode apagar o INI.
if(APPLE)
	add_test(NAME mac-vt-sample COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test_p5m_vt_sample.py")
	add_test(NAME mac-fec COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test_p5m_fec.py")
endif()
if(APPLE AND CHIAKI_ENABLE_GUI)
	add_test(NAME mac-converter COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test_quest2ini.py")
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    find_package(Qt6 REQUIRED COMPONENTS Core)
    add_executable(p5m-logsanitizer test_p5m_logsanitizer.cpp)
    target_include_directories(p5m-logsanitizer PRIVATE ../gui/include)
    target_link_libraries(p5m-logsanitizer Qt6::Core)
    add_test(NAME mac-log-privacy COMMAND p5m-logsanitizer)
    add_executable(p5m-settings-migration test_p5m_settings_migration.cpp)
    target_include_directories(p5m-settings-migration PRIVATE ../gui/include)
    target_link_libraries(p5m-settings-migration Qt6::Core)
    add_test(NAME mac-settings-migration COMMAND p5m-settings-migration)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-hid-async test_p5m_hid_async.cpp)
    target_compile_features(p5m-hid-async PRIVATE cxx_std_17)
    target_include_directories(p5m-hid-async PRIVATE ../gui/include)
    add_test(NAME mac-hid-async COMMAND p5m-hid-async)
    add_test(NAME mac-system-integration COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test_p5m_system_integration.py")
    add_test(NAME mac-hdr COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test_p5m_hdr.py")
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-system-console test_p5m_system_console.cpp)
    target_include_directories(p5m-system-console PRIVATE ../gui/include)
    target_compile_features(p5m-system-console PRIVATE cxx_std_17)
    add_test(NAME mac-system-console COMMAND p5m-system-console)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-mac-audio-ring test_p5m_mac_audio_ring.cpp)
    target_include_directories(p5m-mac-audio-ring PRIVATE ../gui/include)
    target_compile_features(p5m-mac-audio-ring PRIVATE cxx_std_17)
    target_compile_options(p5m-mac-audio-ring PRIVATE -UNDEBUG)
    add_test(NAME mac-audio-ring COMMAND p5m-mac-audio-ring)
endif()

if(CHIAKI_LIB_ENABLE_OPUS)
    add_executable(p5m-audio-decoder test_p5m_audio_decoder.c)
    target_link_libraries(p5m-audio-decoder chiaki-lib)
    add_test(NAME audio-decoder-headers COMMAND p5m-audio-decoder)
endif()
if(APPLE AND CHIAKI_ENABLE_GUI)
    enable_language(OBJCXX)
    add_executable(p5m-mac-audio-validation test_p5m_mac_audio_validation.mm ../gui/src/macAudioOutput.mm)
    target_include_directories(p5m-mac-audio-validation PRIVATE ../gui/include)
    target_compile_features(p5m-mac-audio-validation PRIVATE cxx_std_17)
    target_compile_options(p5m-mac-audio-validation PRIVATE -UNDEBUG)
    target_link_libraries(p5m-mac-audio-validation "-framework Foundation" "-framework AudioToolbox" "-framework CoreAudio")
    add_test(NAME mac-audio-validation COMMAND p5m-mac-audio-validation)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_test(NAME mac-packaging COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test_p5m_packaging.py")
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-hdr-layer test_p5m_hdr_layer.mm)
    target_include_directories(p5m-hdr-layer PRIVATE ../gui/include)
    target_compile_features(p5m-hdr-layer PRIVATE cxx_std_17)
    target_compile_options(p5m-hdr-layer PRIVATE -fobjc-arc)
    target_link_libraries(p5m-hdr-layer "-framework Foundation" "-framework QuartzCore" "-framework CoreGraphics" "-framework Metal")
    add_test(NAME mac-hdr-layer COMMAND p5m-hdr-layer)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-display-pacing test_p5m_display_pacing.cpp)
    target_include_directories(p5m-display-pacing PRIVATE ../gui/include)
    target_compile_features(p5m-display-pacing PRIVATE cxx_std_17)
    target_compile_options(p5m-display-pacing PRIVATE -UNDEBUG)
    add_test(NAME mac-display-pacing COMMAND p5m-display-pacing)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-display-link-layer test_p5m_display_link_layer.mm)
    target_compile_features(p5m-display-link-layer PRIVATE cxx_std_17)
    target_compile_options(p5m-display-link-layer PRIVATE -fobjc-arc -UNDEBUG)
    target_link_libraries(p5m-display-link-layer "-framework Foundation" "-framework QuartzCore" "-framework Metal")
    add_test(NAME mac-display-link-layer COMMAND p5m-display-link-layer)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-presentation-stats test_p5m_presentation_stats.cpp)
    target_include_directories(p5m-presentation-stats PRIVATE ../gui/include)
    target_compile_features(p5m-presentation-stats PRIVATE cxx_std_17)
    target_compile_options(p5m-presentation-stats PRIVATE -UNDEBUG)
    add_test(NAME mac-presentation-stats COMMAND p5m-presentation-stats)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_executable(p5m-render-deadline test_p5m_render_deadline.cpp)
    target_include_directories(p5m-render-deadline PRIVATE ../gui/include)
    target_compile_features(p5m-render-deadline PRIVATE cxx_std_17)
    target_compile_options(p5m-render-deadline PRIVATE -UNDEBUG)
    add_test(NAME mac-render-deadline COMMAND p5m-render-deadline)
endif()

if(APPLE AND CHIAKI_ENABLE_GUI)
    add_test(NAME mac-metal-diagnostics COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test_p5m_metal_diagnostics.py")
endif()
