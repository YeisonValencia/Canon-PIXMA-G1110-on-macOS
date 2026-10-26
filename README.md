# Arquitectura CUPS y Guía de Aprovisionamiento para Canon PIXMA G1110 en macOS 15 (Sequoia)

Este repositorio contiene la arquitectura de subsistema, análisis de controladores y el script automatizado para la habilitación de la impresora **Canon PIXMA G1110** (familia G1000/G1100) en sistemas **macOS 15.x (Sequoia)** con arquitecturas **Apple Silicon (arm64)** e **Intel (x86_64)**.

---

## 1. Evaluación Arquitectónica y Selección del Backend

### Comparativa de Alternativas

| Criterio | Opción A: Gutenprint 5.3 (Canon IJ / BJC) | Opción B: Portar `rastertocanonij` desde Linux (`cnijfilter2`) | Opción C: Driver Canon macOS (G1000 CUPS via Rosetta 2) |
| :--- | :--- | :--- | :--- |
| **Naturaleza del Código** | 100% Open Source (GPL) | Frontend GPL + **Blobs binarios cerrados** (`libcnbp*.so`, `libcnnet*.so`) | Propietario Canon (Mach-O x86_64) |
| **Compatibilidad ABI Darwin** | Nativa (`arm64` / `x86_64` Mach-O) | **Incompatible** (los blobs son Linux ELF x86) | Nativa x86_64 Mach-O (Traducible vía Rosetta 2) |
| **Soporte Apple Silicon** | Completo y sin emulación | Imposible sin emulador de sistema operativo Linux | Transparente bajo Rosetta 2 |
| **Tasa de Éxito / Fricción** | **Menor fricción, alta estabilidad** para impresión estándar | **Falla crítica**: imposibilidad de enlazar blobs ELF con Mach-O | Excelente fidelidad de color, pero requiere paquete Canon |

### Análisis Detallado de la Inviabilidad de la Opción B (Linux CUPS a Darwin)
1. **Dependencia de Binarios Propietarios Cerrados:** El paquete `cnijfilter2` de Canon para Linux proporciona como código abierto únicamente el wrapper superficial de CUPS (`rastertocanonij`). El motor de compresión y rasterización real reside en librerías dinámicas precompiladas como `libcnbpcnre.so`, `libcnbpcore.so` y `libcnnet.so`.
2. **Incompatibilidad de Formato Binario:** macOS utiliza el formato binario ejecutable **Mach-O**, mientras que las librerías de Canon Linux están compiladas en formato **ELF**. El enlazador dinámico de macOS (`dyld`) no puede cargar ni enlazar objetos compartidos ELF.
3. **Limitación de Rosetta 2:** Rosetta 2 es un traductor binario de espacio de usuario específico para binarios Mach-O x86_64 dirigidos al kernel XNU/Darwin. **No es un emulador de Linux**; por tanto, no puede ejecutar llamadas al sistema Linux ni binarios ELF.
4. **Conclusión Técnica:** La opción con menor fricción y garantizada en el ecosistema UNIX libre de macOS es **Gutenprint** (perfil `bjc-PIXMA-G1100` / `bjc-G1000-series`), complementada por la compatibilidad de PPD y filtros de Gutenprint.

---

## 2. Consideraciones Críticas de Seguridad y Permisos en macOS 15 (Sequoia)

### A. System Integrity Protection (SIP) y Firmlinks
En macOS 15, el sistema de archivos raíz (`/`) reside en un volumen sellado criptográficamente (**Signed System Volume - SSV**).
- **Firmlinks de APFS:** Rutas tradicionales de CUPS como `/usr/libexec/cups/filter` y `/Library/Printers/` están redirigidas mediante *firmlinks* al volumen de datos (`/System/Volumes/Data`).
- Esto permite crear enlaces simbólicos y colocar filtros en `/usr/libexec/cups/filter` siempre que se cuente con permisos de superusuario (`sudo`), sin requerir la desactivación de SIP.

### B. Políticas de Permisos de CUPS (`Insecure filter permissions`)
El planificador `cupsd` ejecuta una auditoría de seguridad rigurosa sobre los binarios de filtrado antes de procesar cualquier trabajo. Si un filtro no cumple con los siguientes requisitos, el trabajo se cancela con el error `Stopped - Filter failed`:
1. El propietario debe ser estrictamente `root:wheel` (`chown root:wheel <filtro>`).
2. Los permisos no deben permitir escritura para grupo o mundo (`chmod 755 <filtro>` o `0555`).
3. El directorio contenedor tampoco debe ser modificable por usuarios comunes.

---

## 3. Uso del Script de Automatización `install_canon_g1110.sh`

### Requisitos Previos
1. Terminal con permisos de administrador (`sudo`).
2. Impresora Canon PIXMA G1110 conectada mediante cable USB y encendida.
3. Paquete Gutenprint instalado en `/Library/Printers/Gutenprint.printerDriver` (o los binarios `rastertogutenprint.5.3` y `cups-genppd.5.3`).

### Ejecución Básica
```bash
sudo ./install_canon_g1110.sh
```

### Ejecución con Detección Automática y Modo Depuración (Debug Logging)
```bash
sudo ./install_canon_g1110.sh --debug --default
```

### Especificación Manual de URI (si la impresora no está conectada al momento de la instalación)
```bash
# Obtener el URI con la impresora conectada:
lpinfo -v | grep -i usb

# Ejecutar el instalador especificando la URI detectada:
sudo ./install_canon_g1110.sh -u "usb://Canon/G1000%20series?serial=123456"
```

---

## 4. Guía de Depuración y Diagnóstico del Pipeline de Impresión

### 1. Activar / Desactivar Logging Detallado
```bash
# Activar log de nivel debug:
sudo cupsctl --debug-logging

# Desactivar log (retornar a modo advertencias/errores):
sudo cupsctl --no-debug-logging
```

### 2. Monitoreo en Vivo de Errores de CUPS
```bash
tail -f /var/log/cups/error_log
```
Busque mensajes clave como:
- `PID ... (rastertogutenprint.5.3) exited with no errors` (indica renderizado exitoso).
- `Insecure filter permissions` (permisos incorrectos en el binario del filtro).
- `Unsupported format` (problema de conversión en el filtro `pdftoraster` o `cgpdftoraster`).

### 3. Prueba Aislada del Pipeline Raster (Sin imprimir físicamente)
Permite verificar si CUPS y el filtro `rastertogutenprint.5.3` procesan un PDF correctamente:
```bash
cupsfilter -p /Library/Printers/PPDs/Contents/Resources/Canon_PIXMA_G1110_Gutenprint.ppd.gz \
           -m application/vnd.cups-raster /System/Library/ColorSync/Calibrators/ColorSync\ Calibration.app/Contents/Resources/AppleGenericRGB.icc > /dev/null
```

### 4. Prueba de Impresión Física
```bash
# Imprimir archivo de prueba:
lp -d Canon_PIXMA_G1110 /usr/share/doc/cups/testprint

# Consultar estado de los trabajos en cola:
lpstat -o -p Canon_PIXMA_G1110
```
