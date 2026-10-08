
set(CMAKE_INCLUDE_CURRENT_DIR ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

if(APPLE)
	enable_language(OBJCXX)
endif()

find_package(Qt6 REQUIRED COMPONENTS Core Gui Concurrent Svg Qml Quick Widgets)
if(Qt6_VERSION VERSION_GREATER_EQUAL "6.10.0")
	find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)
endif()

find_package(Qt6 COMPONENTS WebEngineQuick)
find_package(Qt6 COMPONENTS DBus)

if(WIN32)
	add_definitions(-DWIN32_LEAN_AND_MEAN)
endif()

set(SOURCE_FILES
	include/exception.h
	src/main.cpp
	include/discoverymanager.h
	src/discoverymanager.cpp
	include/streamsession.h
	src/streamsession.cpp
	include/sessionlog.h
	src/sessionlog.cpp
	include/settings.h
	src/settings.cpp
	include/host.h
	src/host.cpp
	res/resources.qrc
	include/controllermanager.h
	src/controllermanager.cpp
	include/psnaccountid.h
	src/psnaccountid.cpp
	include/psntoken.h
	src/psntoken.cpp
	include/jsonrequester.h
	src/jsonrequester.cpp
	src/qml/qml.qrc
	include/qmlmainwindow.h
	src/qmlmainwindow.cpp
	include/qmlbackend.h
	src/qmlbackend.cpp
	include/qmlcontroller.h
	src/qmlcontroller.cpp
	include/qmlsettings.h
	src/qmlsettings.cpp
	include/qmlsvgprovider.h
	src/qmlsvgprovider.cpp
	include/systemdinhibit.h
	src/systemdinhibit.cpp
	)
set(RESOURCE_FILES "")

if(APPLE)
	list(APPEND RESOURCE_FILES "chiaking.icns")
elseif(WIN32)
	configure_file(
		${CMAKE_CURRENT_SOURCE_DIR}/chiaking.rc.in
		${CMAKE_CURRENT_SOURCE_DIR}/chiaking.rc
		@ONLY)
	list(APPEND RESOURCE_FILES "chiaking.rc")
endif()

if(CHIAKI_ENABLE_STEAMDECK_NATIVE AND LINUX)
	list(APPEND SOURCE_FILES
		include/sdinputcontext.h
		src/sdinputcontext.cpp
	)
endif()

if(APPLE)
	list(APPEND SOURCE_FILES
		include/macMicPermission.h
		src/macMicPermission.m
		include/macWakeSleep.h
		src/macWakeSleep.cpp
		include/metalrenderer.h
		src/metalrenderer.mm
		include/macControllerGestures.h
		src/macControllerGestures.mm
		include/macStreamActivity.h
		src/macStreamActivity.mm
		include/macDualSenseBluetooth.h
		src/macDualSenseBluetooth.mm
		src/macDualSenseCoreHaptics.mm
		src/macAudioOutput.mm
	)
	set_source_files_properties(src/metalrenderer.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
	set_source_files_properties(src/macDualSenseBluetooth.mm src/macDualSenseCoreHaptics.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
elseif(WIN32)
	list(APPEND SOURCE_FILES
		include/windowsWakeSleep.h
		src/windowsWakeSleep.cpp
	)
endif()

add_executable(chiaki WIN32
		${RESOURCE_FILES}
		${SOURCE_FILES}
)
target_include_directories(chiaki PRIVATE include)

if(APPLE)
    find_program(P5M_XCRUN xcrun REQUIRED)
    execute_process(COMMAND "${P5M_XCRUN}" --sdk macosx --show-sdk-path
        OUTPUT_VARIABLE P5M_MAC_SDK OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
    execute_process(COMMAND xcodebuild -version OUTPUT_VARIABLE P5M_XCODE_VERSION COMMAND_ERROR_IS_FATAL ANY)
    string(REGEX MATCH "Build version ([^\n]+)" P5M_XCODE_BUILD_MATCH "${P5M_XCODE_VERSION}")
    set(P5M_XCODE_BUILD "${CMAKE_MATCH_1}")
    execute_process(COMMAND "${P5M_XCRUN}" --find swiftc OUTPUT_VARIABLE P5M_SWIFTC OUTPUT_STRIP_TRAILING_WHITESPACE)
    get_filename_component(P5M_SWIFT_BIN "${P5M_SWIFTC}" DIRECTORY)
    get_filename_component(P5M_TOOLCHAIN_USR "${P5M_SWIFT_BIN}" DIRECTORY)
    get_filename_component(P5M_TOOLCHAIN "${P5M_TOOLCHAIN_USR}" DIRECTORY)
    set(P5M_BRIDGE_DIR "${CMAKE_CURRENT_BINARY_DIR}/mac-system")
    file(MAKE_DIRECTORY "${P5M_BRIDGE_DIR}")
    file(WRITE "${P5M_BRIDGE_DIR}/protocols.json" "[\"AppIntent\",\"AppEntity\",\"AppShortcutsProvider\",\"EntityQuery\",\"EntityStringQuery\"]")
    file(WRITE "${P5M_BRIDGE_DIR}/sources.txt" "${CMAKE_CURRENT_SOURCE_DIR}/src/macSystemIntegration.swift\n")
    file(WRITE "${P5M_BRIDGE_DIR}/constvalues.txt" "${P5M_BRIDGE_DIR}/macSystemIntegration.swiftconstvalues\n")
    set(P5M_SWIFT_TARGET "${CMAKE_HOST_SYSTEM_PROCESSOR}-apple-macos${CMAKE_OSX_DEPLOYMENT_TARGET}")
    set(P5M_SWIFT_LIBRARY "${P5M_BRIDGE_DIR}/libP5MSystemIntegration.dylib")
    add_custom_command(OUTPUT "${P5M_SWIFT_LIBRARY}" "${P5M_BRIDGE_DIR}/macSystemIntegration.swiftconstvalues"
        COMMAND "${P5M_XCRUN}" swiftc -module-cache-path "${P5M_BRIDGE_DIR}/module-cache"
            -target "${P5M_SWIFT_TARGET}" -emit-library -emit-module -emit-const-values
            -emit-const-values-path "${P5M_BRIDGE_DIR}/macSystemIntegration.swiftconstvalues"
            -const-gather-protocols-list "${P5M_BRIDGE_DIR}/protocols.json"
            -module-name P5MSystemIntegration -swift-version 5 -parse-as-library
            "${CMAKE_CURRENT_SOURCE_DIR}/src/macSystemIntegration.swift"
            -Xlinker -install_name -Xlinker @rpath/libP5MSystemIntegration.dylib
            -o "${P5M_SWIFT_LIBRARY}"
        COMMAND "${P5M_XCRUN}" swiftc -module-cache-path "${P5M_BRIDGE_DIR}/module-cache"
            -target "${P5M_SWIFT_TARGET}" -c -emit-const-values
            -const-gather-protocols-list "${P5M_BRIDGE_DIR}/protocols.json"
            -module-name P5MSystemIntegration -swift-version 5 -parse-as-library
            "${CMAKE_CURRENT_SOURCE_DIR}/src/macSystemIntegration.swift"
            -o "${P5M_BRIDGE_DIR}/macSystemIntegration.o"
        DEPENDS src/macSystemIntegration.swift "${P5M_BRIDGE_DIR}/protocols.json"
        WORKING_DIRECTORY "${P5M_BRIDGE_DIR}" VERBATIM)
    add_custom_target(p5m-system-bridge DEPENDS "${P5M_SWIFT_LIBRARY}")
    add_library(P5MSystemIntegration SHARED IMPORTED)
    set_target_properties(P5MSystemIntegration PROPERTIES IMPORTED_LOCATION "${P5M_SWIFT_LIBRARY}")
    add_dependencies(chiaki p5m-system-bridge)
    target_link_libraries(chiaki P5MSystemIntegration)
    set_property(TARGET chiaki APPEND PROPERTY BUILD_RPATH "@executable_path/../Frameworks" "${P5M_BRIDGE_DIR}")
    add_custom_command(TARGET chiaki POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_DIR:chiaki>/Contents/Frameworks"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${P5M_SWIFT_LIBRARY}" "$<TARGET_BUNDLE_DIR:chiaki>/Contents/Frameworks/"
        COMMAND "${P5M_XCRUN}" appintentsmetadataprocessor
            --output "$<TARGET_BUNDLE_DIR:chiaki>/Contents/Resources"
            --toolchain-dir "${P5M_TOOLCHAIN}" --module-name P5MSystemIntegration
            --sdk-root "${P5M_MAC_SDK}" --xcode-version "${P5M_XCODE_BUILD}"
            --platform-family macOS --deployment-target "${CMAKE_OSX_DEPLOYMENT_TARGET}"
            --target-triple "${P5M_SWIFT_TARGET}"
            --source-file-list "${P5M_BRIDGE_DIR}/sources.txt"
            --swift-const-vals-list "${P5M_BRIDGE_DIR}/constvalues.txt"
        VERBATIM)
endif()


# P5M: the dithered background (Backdrop.qml falls back to a Canvas without it).
find_package(Qt6 COMPONENTS ShaderTools)
if(Qt6ShaderTools_FOUND)
	qt_add_shaders(chiaki "p5m_shaders"
		PREFIX "/"
		BASE src/qml
		FILES src/qml/shaders/backdrop.frag)
endif()

add_library(placebo-libav-impl src/libav_impl.c)
target_link_libraries(placebo-libav-impl PkgConfig::LIBPLACEBO FFMPEG::avcodec FFMPEG::avutil FFMPEG::avformat)
target_link_libraries(chiaki PkgConfig::LIBPLACEBO placebo-libav-impl)

target_link_libraries(chiaki chiaki-lib)
if(CHIAKI_ENABLE_CLI)
	add_definitions(-DCHIAKI_ENABLE_CLI)
	target_link_libraries(chiaki chiaki-cli-lib)
endif()

target_link_libraries(chiaki Qt::Core Qt::Gui Qt::GuiPrivate Qt::Concurrent Qt::Svg Qt::Qml Qt::Quick Qt::Widgets)
if (${Qt6DBus_FOUND} AND NOT WIN32)
	target_link_libraries(chiaki Qt::DBus)
if (NOT APPLE)
	target_compile_definitions(chiaki PRIVATE CHIAKI_HAVE_DBUS)
endif()
endif()
if (${Qt6WebEngineQuick_FOUND})
	target_link_libraries(chiaki Qt::WebEngineQuick)
	target_compile_definitions(chiaki PRIVATE CHIAKI_HAVE_WEBENGINE)
endif()
target_link_libraries(chiaki SDL2::SDL2)
if(CHIAKI_ENABLE_SPEEX)
  target_link_libraries(chiaki PkgConfig::SpeexDSP)
  target_compile_definitions(chiaki PRIVATE CHIAKI_GUI_ENABLE_SPEEX)
endif()
if(CHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER)
	target_compile_definitions(chiaki PRIVATE CHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER)
endif()
if(CHIAKI_ENABLE_SETSU)
	target_link_libraries(chiaki setsu)
	target_compile_definitions(chiaki PRIVATE CHIAKI_GUI_ENABLE_SETSU)
endif()
if(CHIAKI_ENABLE_STEAMDECK_NATIVE)
	target_link_libraries(chiaki sdeck)
	target_compile_definitions(chiaki PRIVATE QT_STATICPLUGIN CHIAKI_GUI_ENABLE_STEAMDECK_NATIVE)
endif()
if(CHIAKI_ENABLE_STEAM_SHORTCUT)
	target_link_libraries(chiaki cpp-steam-tools)
	target_compile_definitions(chiaki PRIVATE CHIAKI_GUI_ENABLE_STEAM_SHORTCUT)
endif()
if(NOT CHIAKI_ENABLE_FFMPEG_DECODER)
	message(FATAL_ERROR "Chiaki GUI requires CHIAKI_ENABLE_FFMPEG_DECODER=ON")
endif()
if(APPLE)
	target_link_libraries(chiaki "-framework AudioToolbox" "-framework CoreAudio" "-framework AVFoundation" "-framework IOKit"
		"-framework AppKit" "-framework Metal" "-framework MetalFX" "-framework QuartzCore" "-framework CoreVideo" "-framework GameController" "-framework CoreHaptics" "-framework SystemConfiguration")
endif()

if(APPLE)
    set(P5M_MAC_VERSION "0.1.0-beta.2" CACHE STRING "P5M macOS release version")
    set(P5M_BUNDLE_NAME "P5M")
    set(P5M_BUNDLE_ID "io.github.beecrepaldi-afk.p5m.mac")
    set(P5M_BUNDLE_VERSION "0.1.0")
    target_compile_definitions(chiaki PRIVATE P5M_MAC_VERSION="${P5M_MAC_VERSION}")
else()
    set(P5M_BUNDLE_NAME "chiaki-ng")
    set(P5M_BUNDLE_ID "org.streetpea.chiaking")
    set(P5M_BUNDLE_VERSION "${CHIAKI_VERSION}")
endif()

# set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fanalyzer")
set_target_properties(chiaki PROPERTIES
		MACOSX_BUNDLE TRUE
		MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/MacOSXBundleInfo.plist.in"
		MACOSX_BUNDLE_BUNDLE_NAME "${P5M_BUNDLE_NAME}"
		MACOSX_BUNDLE_BUNDLE_VERSION "${P5M_BUNDLE_VERSION}"
		MACOSX_BUNDLE_COPYRIGHT "thestr4ng3r (AGPLv3)"
		MACOSX_BUNDLE_GUI_IDENTIFIER "${P5M_BUNDLE_ID}"
		MACOSX_BUNDLE_ICON_FILE chiaking.icns
		RESOURCE "${RESOURCE_FILES}")

install(TARGETS chiaki
		RUNTIME DESTINATION bin
		BUNDLE DESTINATION bin)
install(FILES chiaking.desktop DESTINATION share/applications)
install(FILES chiaking.png DESTINATION share/icons/hicolor/512x512/apps)
install(FILES io.github.streetpea.Chiaki4deck.appdata.xml DESTINATION share/metainfo)

# Framework novo opcional: não impede o app de carregar em versões anteriores.
if(APPLE)
    find_library(P5M_STATE_REPORTING_FRAMEWORK StateReporting)
    if(P5M_STATE_REPORTING_FRAMEWORK)
        target_link_options(chiaki PRIVATE "SHELL:-weak_framework StateReporting")
    endif()
endif()
