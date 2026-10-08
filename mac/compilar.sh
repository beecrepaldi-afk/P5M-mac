#!/bin/bash
# Compila o chiaki-ng no Mac (Apple Silicon) sem sudo.
#
# Dependências, uma vez só:
#   brew install qt@6 ffmpeg pkgconf opus openssl cmake ninja nasm protobuf@29 \
#                speexdsp libplacebo wget python-setuptools json-c miniupnpc libevent
#   SDL3 + sdl2-compat em ~/projetos/_ferramentas/sdl (scripts/build-sdl2-compat.sh
#   com INSTALL_PREFIX apontando para lá; depois copiar sdl2-compat.pc para sdl2.pc)
#   venv com protobuf 5 em ~/projetos/_ferramentas/chiaki-venv (para o nanopb)
#
# Uso: mac/compilar.sh [Release|Debug|RelWithDebInfo]   (padrão RelWithDebInfo)
# Saída: build-mac/gui/chiaki.app

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TIPO="${1:-RelWithDebInfo}"
FERRAMENTAS="$HOME/projetos/_ferramentas"
BREW="$(brew --prefix)"
SDL="$FERRAMENTAS/sdl"

export PKG_CONFIG_PATH="$SDL/lib/pkgconfig:$BREW/opt/openssl@3/lib/pkgconfig:$BREW/lib/pkgconfig"
export CPATH="$BREW/opt/ffmpeg/include"

cmake -S . -B build-mac -G Ninja \
	-DCMAKE_BUILD_TYPE="$TIPO" \
	-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
	-DCHIAKI_ENABLE_CLI=OFF \
	-DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
	-DPYTHON_EXECUTABLE="$FERRAMENTAS/chiaki-venv/bin/python" \
	-DPython3_EXECUTABLE="$FERRAMENTAS/chiaki-venv/bin/python" \
	-DCMAKE_PREFIX_PATH="$SDL;$BREW/opt/openssl@3;$BREW/opt/qt@6;$BREW/opt/protobuf@29"

cmake --build build-mac --target chiaki
