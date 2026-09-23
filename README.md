# Comodo — gestor de ComfyUI para Windows

Gestor en **PowerShell Core (`pwsh`)** que automatiza la instalación, configuración y actualización de **ComfyUI** en Windows usando [`uv`](https://github.com/astral-sh/uv).

El objetivo es que funcione en cualquier equipo: **el perfil de aceleración se deriva de la GPU que se detecte**, no de una configuración fija. Nada de hardware asumido ni de nodos impuestos.

> [!TIP]
> Puedes invocarlo indistintamente como `.\comodo.ps1` o `.\comfy.ps1`.

---

## Inicio rápido

Abre **PowerShell Core (pwsh)** en esta carpeta:

```powershell
# 1. Verificar dependencias (pwsh, uv, git y conectividad)
.\comodo.ps1 pre-requisites

# 2. Detectar la GPU y calcular el perfil para esta máquina
.\comodo.ps1 probe

# 3. Clonar ComfyUI, crear el entorno e instalar lo que corresponda
.\comodo.ps1 provision apply
```

Para iniciar el servidor:

```powershell
.\comodo.ps1 start
```

Abre `http://127.0.0.1:8188` en el navegador.

---

## Qué instala, y según qué

`probe` consulta la GPU (vía `nvidia-smi`, con CIM como respaldo) y decide a partir de la **capacidad de cómputo** y la **VRAM reales**:

| Condición detectada | Consecuencia |
| :--- | :--- |
| GPU NVIDIA, cómputo ≥ 7.5 (serie 20 en adelante) | PyTorch CUDA 13.0 |
| GPU NVIDIA, cómputo < 7.5 (Pascal y anteriores) | PyTorch CUDA 12.6 |
| Cómputo ≥ 7.0 | Se instala `triton-windows` |
| Cómputo ≥ 8.0 | Se instala `sageattention` |
| VRAM < 6 GB | `--lowvram` queda activo por defecto |
| GPU AMD / Intel / sin GPU | Se avisa y **no** se instala nada acelerado |

El objetivo es CUDA 13.0 desde sm_75 porque `comfy_kitchen` —que ComfyUI trae en su `requirements.txt`— **deshabilita sus backends `cuda` y `triton`** si PyTorch se compiló contra una versión anterior. Con cu126 los reporta como `available: True, disabled: True` y se pierden los kernels optimizados sin que nada falle de forma visible. `doctor` detecta ese desajuste.

CUDA 13 ya no soporta Pascal ni anteriores, así que esas GPUs se quedan en la rama 12.x.

### Registro de aceleradores

Los aceleradores se declaran en una sola tabla, `ACCELERATORS` en [`src/probe_hardware.py`](src/probe_hardware.py). Cada fila indica su clave, el extra de `pyproject.toml` que lo instala, el módulo con el que se comprueba, el flag que necesita `main.py` y su capacidad de cómputo mínima.

`probe` evalúa esa tabla contra la GPU detectada y guarda el resultado —con el **motivo** de cada decisión— en `etc/config.json`. A partir de ahí, `provision apply`, `upgrade`, `doctor` y `start` consumen ese registro; ninguno contiene nombres de acelerador escritos en el código.

Añadir uno requiere **dos ediciones**: una fila en la tabla y un extra en `pyproject.toml` (más `uv lock`). Si olvidás el lock, `provision apply` falla de forma visible gracias a `--locked` en vez de instalar algo sin fijar.

Cada acelerador se evalúa por separado, así que una GPU puede cumplir el umbral de uno y no el de otro (una Turing sm_7.5 recibe Triton pero no SageAttention, que exige sm_80).

### ComfyUI-Manager

Desde su **versión 4**, ComfyUI-Manager dejó de ser un nodo que se clona en `custom_nodes/` y pasó a ser un **paquete de PyPI**. Además, ComfyUI 0.37+ lo trae **apagado por defecto**: el argumento cambió de `--disable-manager` (opt-out) a `--enable-manager` (opt-in).

El gestor se adapta a las dos cosas:

- `provision apply` lo instala con `uv pip install -r ComfyUI/manager_requirements.txt`. Se usa **el pin de ComfyUI** (hoy `comfyui_manager==4.2.2`) en lugar de la última de PyPI: es la versión contra la que el núcleo probó, y se actualiza sola al actualizar ComfyUI.
- `start` pasa `--enable-manager` mientras `flag set manager on` esté activo, que es el valor por defecto.

```powershell
.\comodo.ps1 flag set manager off    # arrancar sin Manager
```

`doctor` informa de la versión instalada del paquete.

### DynamicVRAM

`comfy-aimdo` (DynamicVRAM) y `comfy-kitchen` vienen **pineados en el `requirements.txt` de ComfyUI**; este gestor no los instala por separado, pero `doctor` informa de su versión.

Si un dato no se puede determinar (por ejemplo, un driver antiguo que no expone `compute_cap`), el gestor **lo dice y elige la opción conservadora** en lugar de inventar un valor.

**Ningún nodo viene impuesto**: se añaden con `custom-nodes add`.

### Rutas no automatizadas

Este gestor solo automatiza la ruta **CUDA**. Para GPUs AMD (ROCm, DirectML, ZLUDA) o Intel (IPEX) hay que configurar el entorno manualmente; `provision apply` lo advierte y se detiene salvo que pases `--allow-cpu` para instalar explícitamente la variante CPU.

---

## Comandos

| Comando | Alias | Descripción |
| :--- | :--- | :--- |
| `pre-requisites` | `prereqs`, `check` | Valida `pwsh`, `uv`, `git` y conectividad. Ofrece instalar lo que falte vía Winget. |
| `probe` | `detect`, `hardware` | Detecta la GPU y guarda el perfil en `etc/config.json`. |
| `provision apply` | `install` | Clona ComfyUI, crea `.venv` con `uv` e instala PyTorch y los aceleradores aplicables. |
| `start` | `run` | Inicia ComfyUI con la configuración persistente. |
| `custom-nodes` | `nodes` | Gestiona nodos Git (`list`, `add`, `remove`). |
| `accelerators` | `accel` | Lista, activa y desactiva aceleradores (`list`, `enable`, `disable`). |
| `flag <list\|set\|unset>` | | Ajustes que llegan a `main.py` (`etc/config.json`). |
| `provision <list\|set\|unset>` | `prov` | Ajustes de aprovisionamiento (`etc/config.json`). |
| `manager <list\|set\|unset>` | `mgr` | Ajustes de ComfyUI-Manager (`config.ini`). |
| `config` | `get` | Vista de solo lectura de toda la configuración. |
| `upgrade` | `update` | Actualiza ComfyUI, los nodos y los aceleradores habilitados. |
| `doctor` | | Compara el entorno real contra el perfil detectado. |
| `provision reset` | `reset` | Limpia `.venv`, la instalación y la configuración local. Admite `--keep-models`, `--keep-nodes` y `--keep-config`. |
| `help` | `--help`, `-h` | Muestra la ayuda. |

Todos los comandos devuelven un **código de salida** acorde al resultado (`0` correcto, `1` fallo, `2` uso incorrecto), por lo que se pueden encadenar o usar desde scripts.

---

## Opciones por comando

### `pre-requisites`
```powershell
.\comodo.ps1 pre-requisites --dry     # Solo comprueba, no instala nada
```

### `probe`
```powershell
.\comodo.ps1 probe                    # Detecta y guarda el perfil
.\comodo.ps1 probe --show             # Solo muestra, sin escribir configuración
```

### `provision apply` (alias: `install`)
```powershell
.\comodo.ps1 provision apply              # Instalación estándar
.\comodo.ps1 install                      # Lo mismo, más corto
.\comodo.ps1 provision apply --force      # Recrea el entorno virtual desde cero
.\comodo.ps1 provision apply --cuda 12.6  # Fuerza una versión de CUDA concreta
.\comodo.ps1 provision apply --skip-opt   # Omite Triton y SageAttention
.\comodo.ps1 provision apply --skip-nodes # No clona ningún nodo
.\comodo.ps1 provision apply --allow-cpu  # Permite instalar en modo CPU
```

Versiones de CUDA admitidas: `12.6` y `13.0` — las que `pyproject.toml` declara como extras y `uv.lock` fija. Cualquier otra se **rechaza** con un error en vez de sustituirse en silencio.

### `start`
```powershell
.\comodo.ps1 start
.\comodo.ps1 start --lowvram          # Fuerza modo de baja memoria
.\comodo.ps1 start --highvram
.\comodo.ps1 start --port 8189
.\comodo.ps1 start --listen 0.0.0.0   # Acceso desde la red local (sin autenticación)
.\comodo.ps1 start --no-sage
```

Cualquier argumento no reconocido se reenvía tal cual a `main.py` de ComfyUI.

### `custom-nodes`
```powershell
.\comodo.ps1 nodes list
.\comodo.ps1 nodes add https://github.com/usuario/mi-nodo.git
.\comodo.ps1 nodes remove mi-nodo
```

Los nodos añadidos quedan registrados en `etc/config.json`, de modo que un `provision apply` sobre una instalación limpia los reconstruye.

### `accelerators` (alias: `accel`)
```powershell
.\comodo.ps1 accel list               # Qué hay, si está activo y por qué
.\comodo.ps1 accel disable sage       # Desactivar
.\comodo.ps1 accel enable triton      # Activar
```

La clave se resuelve contra el registro: vale la clave exacta, el nombre del paquete (`triton-windows`) o un prefijo inequívoco (`sage` → `sage_attention`). Activar uno que el hardware no soporta se permite, pero avisa.

Los cambios se aplican con `provision apply`. `set <clave> on|off` hace lo mismo y acepta las mismas formas.

### Ajustes: `flag`, `provision` y `manager`

Cada comando escribe en un archivo distinto y con un alcance distinto. Un ajuste pedido en el espacio equivocado no falla con un "clave desconocida": indica el comando correcto.

**`flag`** — lo que termina siendo argumento de `main.py`, en `etc/config.json`:

```powershell
.\comodo.ps1 flag list
.\comodo.ps1 flag set manager off     # arranca sin --enable-manager
.\comodo.ps1 flag set lowvram
.\comodo.ps1 flag set port 8189
.\comodo.ps1 flag set listen 0.0.0.0
.\comodo.ps1 flag unset port
.\comodo.ps1 flag unset all           # Restablece todos los flags
```

**`provision`** — decisiones de aprovisionamiento, también en `etc/config.json`. El mismo espacio contiene `apply`, que es la acción de instalar:

```powershell
.\comodo.ps1 provision list
.\comodo.ps1 provision set cuda 13.0
.\comodo.ps1 provision set python 3.12
.\comodo.ps1 provision apply          # instala (alias: install)
.\comodo.ps1 provision reset          # limpia   (alias: reset)
```

**`manager`** — el `config.ini` de **ComfyUI-Manager** (no del núcleo de ComfyUI):

```powershell
.\comodo.ps1 manager list
.\comodo.ps1 manager set allow_git_url_install True
.\comodo.ps1 manager unset allow_git_url_install
```

Verificado contra ComfyUI-Manager **4.2.2**: la ruta es `ComfyUI/user/__manager/config.ini`, la misma que en V3.38+ (el paquete la resuelve con `folder_paths.get_system_user_directory("manager")`). `allow_git_url_install` sigue existiendo; V4 añade `use_unified_resolver` y `verbose`, y retira `preview_method`, `component_policy` y `allow_flagged_nodepack_install`.

Ese `config.ini` vive dentro del directorio de instalación, que `reset` borra entero. Por eso `manager set` guarda además el valor en `etc/config.json` y **`provision apply` lo reaplica**: no hay que repetirlo tras cada reset. `manager unset` deja de fijarlo pero no revierte el `config.ini`, porque el valor actual puede seguir siendo el deseado.

ComfyUI-Manager lee `config.ini` **al arrancar**, así que los cambios necesitan reiniciar ComfyUI con el servidor detenido.

Los aceleradores tienen su propio comando (`accel`) y no se tocan desde aquí.

### `provision reset` (alias: `reset`)
```powershell
.\comodo.ps1 provision reset              # Pide confirmación
.\comodo.ps1 reset                        # Lo mismo, más corto
.\comodo.ps1 provision reset --force      # Sin preguntar
.\comodo.ps1 provision reset --keep-models # Preserva los modelos (checkpoints, LoRAs...)
.\comodo.ps1 provision reset --keep-nodes  # Preserva ComfyUI/custom_nodes
.\comodo.ps1 provision reset --keep-config # Conserva etc/config.json
```

---

## Reproducibilidad

La capa que este gestor controla (PyTorch y los aceleradores) se declara en `pyproject.toml` y queda fijada en `uv.lock`, ambos versionados. `provision apply` la instala con:

```
uv sync --locked --inexact --extra <objetivo>
```

- **`--locked`** hace que falle de forma visible si el lock no corresponde a `pyproject.toml`, en vez de re-resolver en silencio y producir un entorno distinto al que se probó.
- **`--inexact`** es imprescindible: sin él, `sync` borraría las dependencias de ComfyUI, que se instalan aparte porque las controla el repositorio upstream.

Las dependencias de ComfyUI se instalan **después** del `sync`, a propósito: ComfyUI controla su propio `requirements.txt` y debe tener la última palabra sobre las dependencias compartidas (`numpy`, `networkx`…), que declara de forma holgada.

Subir de versión es un cambio deliberado del lock, no un efecto secundario de actualizar:

```powershell
uv lock --upgrade-package sageattention
```

## Desarrollo

```powershell
pwsh -File tests/Invoke-Checks.ps1
```

Ejecuta PSScriptAnalyzer, Pester, pytest y `uv lock --check`. Los módulos de PowerShell se buscan en `.psmodules/` del repositorio, para no depender del perfil del usuario:

```powershell
New-Item -ItemType Directory -Path .psmodules -Force
Save-PSResource -Name Pester -Path .psmodules -TrustRepository
Save-PSResource -Name PSScriptAnalyzer -Path .psmodules -TrustRepository
```

Lo mismo se ejecuta en CI sobre `windows-latest` (`.github/workflows/ci.yml`).

---

## Estructura

```text
.
├── comodo.ps1               # Punto de entrada
├── comfy.ps1                # Alias de comodo.ps1
├── etc/
│   └── config.example.json  # Plantilla (config.json es local y está en .gitignore)
├── pyproject.toml           # Capa gestionada: objetivos de PyTorch y aceleradores
├── uv.lock                  # Versiones exactas (versionado)
├── tests/
│   ├── Invoke-Checks.ps1    # Lint + pruebas + verificacion del lock
│   ├── Common.Tests.ps1     # Pester
│   ├── Config.Tests.ps1     # Pester
│   └── test_probe_hardware.py  # pytest: matriz de decision del probe
└── src/
    ├── Common.psm1          # Consola, localización de binarios, índices de CUDA
    ├── Config.psm1          # Carga, normalización y persistencia de configuración
    ├── Checker.psm1         # Requisitos previos (pre-requisites)
    ├── Probe.psm1           # Detección de hardware (probe)
    ├── probe_hardware.py    # Detección de GPU, solo biblioteca estándar
    ├── Installer.psm1       # Clonado y aprovisionamiento (provision apply)
    ├── Runner.psm1          # Lanzador (start)
    ├── Nodes.psm1           # Nodos personalizados
    ├── Updater.psm1         # Actualizaciones (upgrade)
    ├── Doctor.psm1          # Diagnóstico (doctor)
    └── Cleaner.psm1         # Limpieza (reset)
```

`etc/config.json` es local a cada máquina y no se versiona: contiene el hardware detectado y las preferencias del usuario.

---

## Requisitos

- Windows 10/11
- [PowerShell Core 7+](https://github.com/PowerShell/PowerShell)
- [`uv`](https://github.com/astral-sh/uv) y `git` (el comando `pre-requisites` puede instalarlos con Winget)
- Para la ruta acelerada: GPU NVIDIA con driver reciente

---

## Licencia

MIT.
