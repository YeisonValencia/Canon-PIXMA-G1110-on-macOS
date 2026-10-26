#!/usr/bin/env bash
# ==============================================================================
# Script: install_canon_g1110.sh
# Descripción: Automatización para la compilación, aprovisionamiento y registro
#              en CUPS de la impresora USB Canon PIXMA G1110 en macOS 15.x (Sequoia)
#              tanto para Apple Silicon (arm64 con Rosetta 2) como para Intel (x86_64).
# Autor: Senior Systems & CUPS Infrastructure Engineer
# ==============================================================================

set -euo pipefail

# --- Colores y formato para logging ---
readonly CLR_RESET="\033[0m"
readonly CLR_BOLD="\033[1m"
readonly CLR_RED="\033[31m"
readonly CLR_GREEN="\033[32m"
readonly CLR_YELLOW="\033[33m"
readonly CLR_BLUE="\033[34m"
readonly CLR_CYAN="\033[36m"

log_info()    { printf "${CLR_BLUE}[INFO]${CLR_RESET} %s\n" "$*"; }
log_success() { printf "${CLR_GREEN}[OK]${CLR_RESET} %s\n" "$*"; }
log_warn()    { printf "${CLR_YELLOW}[WARN]${CLR_RESET} %s\n" "$*"; }
log_error()   { printf "${CLR_RED}[ERROR]${CLR_RESET} %s\n" "$*" >&2; }
log_step()    { printf "\n${CLR_BOLD}${CLR_CYAN}===> %s${CLR_RESET}\n" "$*"; }

# --- Rutas de CUPS y directorios del sistema en macOS ---
readonly CUPS_FILTER_DIR="/usr/libexec/cups/filter"
readonly PPD_RESOURCE_DIR="/Library/Printers/PPDs/Contents/Resources"
readonly GUTENPRINT_DIR="/Library/Printers/Gutenprint.printerDriver"
readonly GUTENPRINT_MACOS="${GUTENPRINT_DIR}/Contents/MacOS"
readonly QUEUE_NAME="Canon_PIXMA_G1110"
readonly PRINTER_DESC="Canon PIXMA G1110 (CUPS IJ Raster)"
readonly PRINTER_LOC="Local USB"
readonly PPD_OUTPUT_NAME="Canon_PIXMA_G1110_Gutenprint.ppd.gz"
readonly TARGET_PPD_PATH="${PPD_RESOURCE_DIR}/${PPD_OUTPUT_NAME}"

# Opciones por defecto
ENABLE_DEBUG=false
SET_AS_DEFAULT=false
OVERRIDE_URI=""

usage() {
    cat <<EOF
Uso: sudo $0 [OPCIONES]

Opciones:
  -u, --uri <URI>        Especifica manualmente la URI de conexión (ej: usb://Canon/G1000%20series?serial=XXXXX).
  -d, --default          Establece la impresora configurada como la predeterminada del sistema.
  --debug                Habilita registro detallado (debug logging) en el demonio CUPS.
  -h, --help             Muestra este mensaje de ayuda.

Ejemplo:
  sudo $0 --debug
  sudo $0 -u "usb://Canon/G1000%20series?serial=123456"
EOF
    exit 0
}

# Parseo de argumentos de línea de comandos
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--uri)
            OVERRIDE_URI="$2"
            shift 2
            ;;
        -d|--default)
            SET_AS_DEFAULT=true
            shift
            ;;
        --debug)
            ENABLE_DEBUG=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Opción no reconocida: $1"
            usage
            ;;
    esac
done

# ==============================================================================
# 1. VERIFICACIÓN DE PERMISOS Y ENTORNO MACOS
# ==============================================================================
log_step "1. Validando privilegios, versión de macOS y arquitectura del procesador"

if [[ "${EUID}" -ne 0 ]]; then
    log_error "Este instalador debe ser ejecutado con privilegios de superusuario (root)."
    printf "Ejecute: sudo %s\n" "$0"
    exit 1
fi

OS_NAME="$(uname -s)"
if [[ "${OS_NAME}" != "Darwin" ]]; then
    log_error "Este script está optimizado exclusivamente para el subsistema Darwin (macOS)."
    exit 1
fi

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
log_info "Sistema detectado: macOS ${OS_VERSION} (Build ${OS_BUILD}), Arquitectura: ${ARCH}"

# En Apple Silicon (arm64), verificar que Rosetta 2 esté habilitado para los filtros CUPS
if [[ "${ARCH}" == "arm64" ]]; then
    log_info "Arquitectura Apple Silicon (arm64) detectada. Verificando subsistema Rosetta 2..."
    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        log_warn "Rosetta 2 no está instalado. Instalándolo ahora..."
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        log_success "Rosetta 2 instalado exitosamente."
    else
        log_success "Rosetta 2 se encuentra activo y operativo."
    fi
fi

# ==============================================================================
# 2. VALIDACIÓN DE DEPENDENCIAS Y SUBSISTEMA CUPS
# ==============================================================================
log_step "2. Comprobando herramientas del sistema y utilidades de CUPS"

readonly REQUIRED_BINARIES=(
    "lpadmin"
    "lpinfo"
    "lpstat"
    "cupsctl"
    "cupsenable"
    "cupsaccept"
    "gzip"
)

for bin in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "${bin}" &>/dev/null; then
        log_error "Herramienta obligatoria no encontrada en el PATH: ${bin}"
        exit 1
    fi
done
log_success "Todas las utilidades de línea de comandos de CUPS están presentes."

# ==============================================================================
# 3. VERIFICACIÓN Y ENLACE DEL FILTRO RASTER DE CUPS
# ==============================================================================
log_step "3. Verificando backend de rasterización (Gutenprint Canon IJ)"

if [[ ! -d "${GUTENPRINT_DIR}" ]]; then
    log_warn "No se encontró el paquete de controladores Gutenprint en ${GUTENPRINT_DIR}."
    log_info "¿Desea descargar e instalar automáticamente Gutenprint 5.3.3 para macOS? [s/N]"
    read -r -p "> " RESP || RESP="n"
    if [[ "${RESP}" =~ ^[sSyY]$ ]]; then
        log_info "Descargando Gutenprint 5.3.3..."
        TMP_PKG_DIR="$(mktemp -d -t gutenprint_install_XXXXXX)"
        CURL_URL="https://downloads.sourceforge.net/project/gimp-print/gutenprint-5.3/5.3.3/gutenprint-5.3.3_rev.dmg"
        curl -L -f -o "${TMP_PKG_DIR}/gutenprint.dmg" "${CURL_URL}"
        
        log_info "Montando imagen DMG..."
        MOUNT_PT="$(hdiutil attach "${TMP_PKG_DIR}/gutenprint.dmg" -nobrowse | grep -o '/Volumes/.*' | head -n 1)"
        
        PKG_FILE="$(find "${MOUNT_PT}" -name "*.pkg" | head -n 1)"
        if [[ -n "${PKG_FILE}" && -f "${PKG_FILE}" ]]; then
            log_info "Instalando paquete ${PKG_FILE}..."
            installer -pkg "${PKG_FILE}" -target /
            log_success "Gutenprint instalado exitosamente."
        else
            log_error "No se encontró archivo .pkg dentro de la imagen montada."
        fi
        
        hdiutil detach "${MOUNT_PT}" -quiet || true
        rm -rf "${TMP_PKG_DIR}"
    else
        log_error "Gutenprint es requerido. Puede descargarlo manualmente desde:"
        log_error "https://sourceforge.net/projects/gimp-print/files/gutenprint-5.3/5.3.3/gutenprint-5.3.3_rev.dmg/download"
        exit 1
    fi
fi

readonly RASTER_FILTER_SRC="${GUTENPRINT_MACOS}/rastertogutenprint.5.3"
readonly COMMAND_CANON_SRC="${GUTENPRINT_MACOS}/commandtocanon"
readonly CUPS_GENPPD_BIN="${GUTENPRINT_MACOS}/cups-genppd.5.3"

if [[ ! -f "${RASTER_FILTER_SRC}" ]]; then
    log_error "Filtro raster no encontrado en: ${RASTER_FILTER_SRC}"
    exit 1
fi

if [[ ! -f "${CUPS_GENPPD_BIN}" ]]; then
    log_error "Generador de PPD no encontrado en: ${CUPS_GENPPD_BIN}"
    exit 1
fi

# Asegurar permisos correctos en el binario fuente
chmod 755 "${RASTER_FILTER_SRC}" "${COMMAND_CANON_SRC}" "${CUPS_GENPPD_BIN}"
chown root:wheel "${RASTER_FILTER_SRC}" "${COMMAND_CANON_SRC}" "${CUPS_GENPPD_BIN}"

# Enlazar o colocar en /usr/libexec/cups/filter/
# NOTA DE SEGURIDAD CUPS: CUPS aborta la ejecución de filtros si tienen permisos de
# escritura para grupo o mundo (Insecure filter permissions). Deben ser 755 y root:wheel.
mkdir -p "${CUPS_FILTER_DIR}"

ensure_symlink() {
    local src="$1"
    local dst="$2"
    if [[ -L "${dst}" ]]; then
        local current_target
        current_target="$(readlink "${dst}")"
        if [[ "${current_target}" == "${src}" ]]; then
            log_info "Enlace simbólico correcto ya existe: ${dst} -> ${src}"
            return 0
        fi
        rm -f "${dst}"
    elif [[ -e "${dst}" ]]; then
        rm -rf "${dst}"
    fi

    ln -s "${src}" "${dst}"
    log_success "Enlace simbólico creado: ${dst} -> ${src}"
}

ensure_symlink "${RASTER_FILTER_SRC}" "${CUPS_FILTER_DIR}/rastertogutenprint.5.3"
ensure_symlink "${COMMAND_CANON_SRC}" "${CUPS_FILTER_DIR}/commandtocanon"

# ==============================================================================
# 4. GENERACIÓN E INSTALACIÓN DEL ARCHIVO PPD (CANON G1000/G1100/G1110)
# ==============================================================================
log_step "4. Generando e instalando el archivo PPD optimizado para Canon G1110"

TMP_DIR="$(mktemp -d -t canon_g1110_ppd_XXXXXX)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# Identificar modelo en Gutenprint:
# bjc-PIXMA-G1100 es idéntico a nivel de comando raster al G1110 (variante regional latinoamericana)
readonly GUTENPRINT_MODEL="bjc-PIXMA-G1100"
log_info "Compilando PPD para el perfil del motor: ${GUTENPRINT_MODEL}..."

if ! "${CUPS_GENPPD_BIN}" -p "${TMP_DIR}" "${GUTENPRINT_MODEL}"; then
    log_error "Error al ejecutar cups-genppd.5.3 para ${GUTENPRINT_MODEL}."
    exit 1
fi

GENERATED_PPD_FILE="${TMP_DIR}/stp-${GUTENPRINT_MODEL}.5.3.ppd.gz"
if [[ ! -f "${GENERATED_PPD_FILE}" ]]; then
    log_error "El archivo PPD generado no existe: ${GENERATED_PPD_FILE}"
    exit 1
fi

mkdir -p "${PPD_RESOURCE_DIR}"
cp -f "${GENERATED_PPD_FILE}" "${TARGET_PPD_PATH}"
chmod 644 "${TARGET_PPD_PATH}"
chown root:wheel "${TARGET_PPD_PATH}"

log_success "PPD instalado correctamente en: ${TARGET_PPD_PATH}"

# ==============================================================================
# 5. DETECCIÓN DEL PUERTO USB Y URI DEL DISPOSITIVO
# ==============================================================================
log_step "5. Detectando la impresora Canon PIXMA G1110 en los buses USB locales"

DETECTED_URI=""
if [[ -n "${OVERRIDE_URI}" ]]; then
    DETECTED_URI="${OVERRIDE_URI}"
    log_info "Usando URI proporcionada por el usuario: ${DETECTED_URI}"
else
    # Escanear backend USB de CUPS
    # Formatos típicos de Canon:
    # direct usb://Canon/G1000%20series?serial=...
    # direct usb://Canon/G1100%20series?serial=...
    # direct usb://Canon/G1110...
    set +e
    RAW_USB_DEVICES="$(lpinfo -v 2>/dev/null | grep -iE 'usb://.*canon' || true)"
    set -e

    if [[ -n "${RAW_USB_DEVICES}" ]]; then
        # Extraer la URI del primer match compatible
        DETECTED_URI="$(echo "${RAW_USB_DEVICES}" | head -n 1 | awk '{print $2}')"
        log_success "Dispositivo USB detectado: ${DETECTED_URI}"
    else
        log_warn "No se detectó ninguna impresora Canon conectada y encendida en el bus USB."
        log_warn "Se configurará la cola con el URI comodín de la serie G1000/G1100."
        log_warn "Al conectar el cable USB, CUPS vinculará automáticamente el endpoint."
        DETECTED_URI="usb://Canon/G1000%20series"
    fi
fi

# ==============================================================================
# 6. CONFIGURACIÓN DEL DEMONIO CUPS Y REGISTRO DE LA COLA
# ==============================================================================
log_step "6. Registrando la cola de impresión mediante lpadmin"

# Si la cola ya existe, eliminarla previamente para evitar conflictos de metadatos
if lpstat -p "${QUEUE_NAME}" &>/dev/null; then
    log_info "La cola '${QUEUE_NAME}' ya existe. Actualizando configuración..."
    lpadmin -x "${QUEUE_NAME}" 2>/dev/null || true
fi

# Configuración con lpadmin:
# -p : Nombre de la cola de impresión
# -E : Habilita la impresora y acepta trabajos de inmediato
# -v : URI del dispositivo (DeviceURI)
# -P : Ruta absoluta al archivo PostScript Printer Description (PPD)
# -D : Descripción legible para el usuario en System Settings
# -L : Ubicación física
lpadmin \
    -p "${QUEUE_NAME}" \
    -E \
    -v "${DETECTED_URI}" \
    -P "${TARGET_PPD_PATH}" \
    -D "${PRINTER_DESC}" \
    -L "${PRINTER_LOC}" \
    -o printer-is-shared=false \
    -o PageSize=Letter

log_success "Cola '${QUEUE_NAME}' creada y vinculada al PPD."

# Habilitar cola y aceptar trabajos de impresión
cupsenable "${QUEUE_NAME}"
cupsaccept "${QUEUE_NAME}"

if [[ "${SET_AS_DEFAULT}" == true ]]; then
    log_info "Estableciendo '${QUEUE_NAME}' como impresora predeterminada..."
    lpadmin -d "${QUEUE_NAME}"
    log_success "Impresora predeterminada configurada."
fi

# ==============================================================================
# 7. GESTIÓN DE REGISTRO / DEBUG Y REINICIO DE CUPSD
# ==============================================================================
log_step "7. Sincronizando demonio org.cups.cupsd"

if [[ "${ENABLE_DEBUG}" == true ]]; then
    log_info "Activando registro extendido de depuración (cupsctl --debug-logging)..."
    cupsctl --debug-logging
else
    cupsctl --no-debug-logging
fi

# En macOS 15, recargar el demonio mediante launchctl kickstart
log_info "Reiniciando el servicio de impresión org.cups.cupsd vía launchctl..."
if launchctl list | grep -q "org.cups.cupsd"; then
    launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
fi

sleep 1

# ==============================================================================
# 8. VERIFICACIÓN FINAL Y ESTADO DEL SISTEMA
# ==============================================================================
log_step "8. Diagnóstico y estado final de la impresora"

printf "\n${CLR_BOLD}Estado actual de la cola en CUPS:${CLR_RESET}\n"
lpstat -p "${QUEUE_NAME}" -l || true

printf "\n${CLR_BOLD}Opciones de impresión configuradas (PageSize, Media, Resolution):${CLR_RESET}\n"
lpoptions -p "${QUEUE_NAME}" -l | head -n 10 || true

cat <<EOF

--------------------------------------------------------------------------------
${CLR_GREEN}${CLR_BOLD}¡INSTALACIÓN COMPLETADA EXITOSAMENTE!${CLR_RESET}
--------------------------------------------------------------------------------
Impresora registrada: ${CLR_BOLD}${QUEUE_NAME}${CLR_RESET}
PPD utilizado:        ${TARGET_PPD_PATH}
URI de conexión:      ${DETECTED_URI}

Comandos útiles de diagnóstico y prueba:
  1. Enviar una página de prueba:
     ${CLR_CYAN}lp -d ${QUEUE_NAME} /System/Library/ColorSync/Calibrators/ColorSync\ Calibration.app/Contents/Resources/AppleGenericRGB.icc${CLR_RESET}
     o imprimir cualquier documento PDF/TXT:
     ${CLR_CYAN}lp -d ${QUEUE_NAME} mi_archivo.pdf${CLR_RESET}

  2. Monitorear el log de procesamiento de filtros en vivo:
     ${CLR_CYAN}tail -f /var/log/cups/error_log${CLR_RESET}

  3. Comprobar el estado de la cola y trabajos en buffer:
     ${CLR_CYAN}lpstat -o -p ${QUEUE_NAME}${CLR_RESET}

  4. Limpiar trabajos atascados:
     ${CLR_CYAN}cancel -a -x ${QUEUE_NAME}${CLR_RESET}
--------------------------------------------------------------------------------
EOF

exit 0
