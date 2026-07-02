cmake_minimum_required(VERSION 3.21)
project(PremiereAnonymizer LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT APPLE)
	message(FATAL_ERROR "This project currently targets macOS (Metal) only.")
endif()

# Apple Silicon only by default; pass -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
# for a universal build if Intel Macs must be supported.
if(NOT CMAKE_OSX_ARCHITECTURES)
	set(CMAKE_OSX_ARCHITECTURES "arm64")
endif()
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
	set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
endif()

# ---- Edition branding ----
# Editions live in editions/<name>.cmake; "oss" (default) is the open-source
# Multi-Layer Anonymizer. Custom-branded editions define the same variables
# with different names/identifiers - the algorithm is identical, and
# differently-branded builds can be installed side by side.
set(ANON_EDITION "oss" CACHE STRING "Branding edition (see editions/*.cmake)")

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/editions/${ANON_EDITION}.cmake")
	message(FATAL_ERROR "Unknown ANON_EDITION '${ANON_EDITION}' - no editions/${ANON_EDITION}.cmake")
endif()
include("${CMAKE_CURRENT_SOURCE_DIR}/editions/${ANON_EDITION}.cmake")

set(ANON_VERSION "1.4.0")

# Branding values consumed by scripts/make_pkg.sh and the install scripts.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/edition.sh"
"EDITION=\"${ANON_EDITION}\"
EFFECT_NAME=\"${ANON_EFFECT_NAME}\"
BUNDLE_BASE=\"${ANON_BUNDLE_BASE}\"
APP_NAME=\"${ANON_APP_NAME}\"
PKG_BASENAME=\"${ANON_PKG_BASENAME}\"
PKG_TITLE=\"${ANON_PKG_TITLE}\"
VERSION=\"${ANON_VERSION}\"
ID_PREMIERE=\"${ANON_ID_PREMIERE}\"
ID_OFX=\"${ANON_ID_OFX}\"
ID_FCP=\"${ANON_ID_FCP_APP}\"
ID_FCP_SERVICE=\"${ANON_ID_FCP_SERVICE}\"
")

# SDK locations. Default to the vendored copies in sdk/; point these at your
# official Adobe SDK downloads instead (same Examples/ layout).
set(AE_SDK_PATH "${CMAKE_CURRENT_SOURCE_DIR}/sdk/aftereffects" CACHE PATH
	"After Effects SDK root (the folder containing Examples/)")
set(PR_SDK_PATH "${CMAKE_CURRENT_SOURCE_DIR}/sdk/premiere" CACHE PATH
	"Premiere Pro SDK root (the folder containing Examples/)")

foreach(_hdr "${AE_SDK_PATH}/Examples/Headers/AE_Effect.h" "${PR_SDK_PATH}/Examples/Headers/PrSDKGPUFilter.h")
	if(NOT EXISTS "${_hdr}")
		message(FATAL_ERROR "SDK header not found: ${_hdr}\nSet AE_SDK_PATH / PR_SDK_PATH (see README.md).")
	endif()
endforeach()

add_library(Anonymizer MODULE
	src/Anonymizer_CPU.cpp
	src/Anonymizer_GPU.mm
)

target_include_directories(Anonymizer PRIVATE
	src
	shared
	"${AE_SDK_PATH}/Examples/Headers"
	"${AE_SDK_PATH}/Examples/Headers/SP"
	"${AE_SDK_PATH}/Examples/Util"
	"${AE_SDK_PATH}/Examples/Resources"
	"${PR_SDK_PATH}/Examples/Headers"
)

# PrGPUFilterModule.h lives in the GPU sample Utils folder of the official
# Premiere SDK; the vendored copy keeps it under GPUUtils/.
foreach(_dir
	"${PR_SDK_PATH}/GPUUtils"
	"${PR_SDK_PATH}/Examples/Projects/GPUVideoFilter/Utils")
	if(EXISTS "${_dir}")
		target_include_directories(Anonymizer PRIVATE "${_dir}")
	endif()
endforeach()

target_link_libraries(Anonymizer PRIVATE
	"-framework Metal"
	"-framework Foundation"
)

target_compile_definitions(Anonymizer PRIVATE
	ANONYMIZER_NAME="${ANON_EFFECT_NAME}"
	ANONYMIZER_MATCH_NAME="${ANON_MATCH_NAME}"
	ANONYMIZER_CATEGORY="${ANON_CATEGORY}"
)

set_target_properties(Anonymizer PROPERTIES
	BUNDLE TRUE
	BUNDLE_EXTENSION "plugin"
	OUTPUT_NAME "${ANON_BUNDLE_BASE}"
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/src/Info.plist.in"
)

# ---- PiPL: compile src/Anonymizer.r with Rez into the bundle resources ----
set(PIPL_RSRC "${CMAKE_CURRENT_BINARY_DIR}/${ANON_BUNDLE_BASE}.rsrc")
add_custom_command(
	OUTPUT "${PIPL_RSRC}"
	COMMAND xcrun Rez
		-useDF
		-d AE_PROC_INTELx64=1
		-d "ANON_PIPL_NAME=\"${ANON_EFFECT_NAME}\""
		-d "ANON_PIPL_CATEGORY=\"${ANON_CATEGORY}\""
		-d "ANON_PIPL_MATCH_NAME=\"${ANON_MATCH_NAME}\""
		-i "${AE_SDK_PATH}/Examples/Headers"
		-i "${AE_SDK_PATH}/Examples/Resources"
		-o "${PIPL_RSRC}"
		"${CMAKE_CURRENT_SOURCE_DIR}/src/Anonymizer.r"
	DEPENDS
		"${CMAKE_CURRENT_SOURCE_DIR}/src/Anonymizer.r"
	COMMENT "Rezzing PiPL"
	VERBATIM
)
add_custom_target(AnonymizerPiPL DEPENDS "${PIPL_RSRC}")
add_dependencies(Anonymizer AnonymizerPiPL)

add_custom_command(TARGET Anonymizer POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_CONTENT_DIR:Anonymizer>/Resources"
	COMMAND ${CMAKE_COMMAND} -E copy_if_different "${PIPL_RSRC}" "$<TARGET_BUNDLE_CONTENT_DIR:Anonymizer>/Resources/${ANON_BUNDLE_BASE}.rsrc"
	COMMAND /bin/sh -c "printf 'eFKTFXTC' > '$<TARGET_BUNDLE_CONTENT_DIR:Anonymizer>/PkgInfo'"
	COMMENT "Placing PiPL and PkgInfo into bundle"
	VERBATIM
)

# ---- OpenFX plugin for DaVinci Resolve (and other OFX hosts) ----
# Uses the vendored OFX 1.4 SDK + Blackmagic's Support library (BSD licensed,
# see ofx/openfx/LICENSE).
file(GLOB OFX_SUPPORT_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/ofx/openfx/Support/Library/*.cpp")
list(FILTER OFX_SUPPORT_SOURCES EXCLUDE REGEX "HWNDInteract")

add_library(AnonymizerOFX MODULE
	ofx/AnonymizerOFX.cpp
	ofx/AnonymizerOFXMetal.mm
	${OFX_SUPPORT_SOURCES}
)

target_include_directories(AnonymizerOFX PRIVATE
	shared
	ofx/openfx/include
	ofx/openfx/Support/include
)

target_link_libraries(AnonymizerOFX PRIVATE
	"-framework Metal"
	"-framework Foundation"
)

target_compile_definitions(AnonymizerOFX PRIVATE
	ANON_EFFECT_NAME="${ANON_EFFECT_NAME}"
	ANON_CATEGORY="${ANON_CATEGORY}"
	ANON_OFX_PLUGIN_ID="${ANON_OFX_PLUGIN_ID}"
)

set_target_properties(AnonymizerOFX PROPERTIES
	OUTPUT_NAME "${ANON_BUNDLE_BASE}"
	PREFIX ""
	SUFFIX ".ofx"
	CXX_VISIBILITY_PRESET hidden
)

configure_file(ofx/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/ofx-Info.plist" @ONLY)

# Assemble the .ofx.bundle layout next to the Premiere bundle.
set(OFX_BUNDLE_DIR "${CMAKE_CURRENT_BINARY_DIR}/${ANON_BUNDLE_BASE}.ofx.bundle")
add_custom_command(TARGET AnonymizerOFX POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E make_directory "${OFX_BUNDLE_DIR}/Contents/MacOS"
	COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:AnonymizerOFX>" "${OFX_BUNDLE_DIR}/Contents/MacOS/${ANON_BUNDLE_BASE}.ofx"
	COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_BINARY_DIR}/ofx-Info.plist" "${OFX_BUNDLE_DIR}/Contents/Info.plist"
	COMMENT "Assembling ${ANON_BUNDLE_BASE}.ofx.bundle"
	VERBATIM
)

# ---- FxPlug 4 plugin for Final Cut Pro / Motion ----
# Requires the FxPlug SDK (https://developer.apple.com/download/all/?q=FxPlug).
# Headers live in the SDK; the redistributable runtime frameworks (embedded
# by scripts/assemble_fxplug.sh) live in /Library/Developer/Frameworks.
set(FXPLUG_FRAMEWORK_DIR "/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks")
if(EXISTS "${FXPLUG_FRAMEWORK_DIR}/FxPlug.framework")
	add_executable(AnonymizerFxPlugService
		fcp/main.m
		fcp/AnonymizerPlugIn.mm
		fcp/AnonMetalCache.m
	)
	target_include_directories(AnonymizerFxPlugService PRIVATE shared fcp)
	target_compile_options(AnonymizerFxPlugService PRIVATE -fobjc-arc)
	target_link_options(AnonymizerFxPlugService PRIVATE
		"-Wl,-rpath,@loader_path/../Frameworks"
		"-F${FXPLUG_FRAMEWORK_DIR}"
	)
	target_compile_options(AnonymizerFxPlugService PRIVATE "-F${FXPLUG_FRAMEWORK_DIR}")
	target_link_libraries(AnonymizerFxPlugService PRIVATE
		"-framework FxPlug"
		"-framework Metal"
		"-framework IOSurface"
		"-framework CoreMedia"
		"-framework AppKit"
		"-framework Foundation"
	)

	add_executable(AnonymizerFxPlugApp fcp/app_main.m)
	target_compile_options(AnonymizerFxPlugApp PRIVATE -fobjc-arc)
	target_compile_definitions(AnonymizerFxPlugApp PRIVATE
		ANON_EFFECT_NAME="${ANON_EFFECT_NAME}"
		ANON_CATEGORY="${ANON_CATEGORY}"
	)
	target_link_libraries(AnonymizerFxPlugApp PRIVATE "-framework Cocoa")

	configure_file(fcp/Info-Service.plist.in "${CMAKE_CURRENT_BINARY_DIR}/fcp-plists/Info-Service.plist" @ONLY)
	configure_file(fcp/Info-App.plist.in "${CMAKE_CURRENT_BINARY_DIR}/fcp-plists/Info-App.plist" @ONLY)
	configure_file(fcp/version.plist.in "${CMAKE_CURRENT_BINARY_DIR}/fcp-plists/version.plist" @ONLY)

	# Assemble as a separate target driven by both binaries, so a change to
	# either the app or the XPC service re-assembles the bundle.
	set(FXPLUG_APP_STAMP "${CMAKE_CURRENT_BINARY_DIR}/fxplug-app.stamp")
	add_custom_command(
		OUTPUT "${FXPLUG_APP_STAMP}"
		COMMAND /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/scripts/assemble_fxplug.sh"
			"${CMAKE_CURRENT_BINARY_DIR}"
			"${CMAKE_CURRENT_SOURCE_DIR}"
			"$<TARGET_FILE:AnonymizerFxPlugApp>"
			"$<TARGET_FILE:AnonymizerFxPlugService>"
		COMMAND ${CMAKE_COMMAND} -E touch "${FXPLUG_APP_STAMP}"
		DEPENDS
			AnonymizerFxPlugApp
			AnonymizerFxPlugService
			"${CMAKE_CURRENT_SOURCE_DIR}/scripts/assemble_fxplug.sh"
			"${CMAKE_CURRENT_BINARY_DIR}/fcp-plists/Info-Service.plist"
			"${CMAKE_CURRENT_BINARY_DIR}/fcp-plists/Info-App.plist"
		COMMENT "Assembling and signing ${ANON_APP_NAME}.app (FxPlug)"
		VERBATIM
	)
	add_custom_target(AnonymizerFxPlugBundle ALL DEPENDS "${FXPLUG_APP_STAMP}")
else()
	message(STATUS "FxPlug SDK not found - skipping the Final Cut Pro plugin")
endif()
