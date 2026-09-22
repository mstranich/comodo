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
.\comodo.ps1 setup
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

`probe` evalúa esa tabla contra la GPU detectada y guarda el resultado —con el **motivo** de cada decisión— en `etc/config.json`. A partir de ahí, `setup`, `upgrade`, `doctor` y `start` consumen ese registro; ninguno contiene nombres de acelerador escritos en el código.

Añadir uno requiere **dos ediciones**: una fila en la tabla y un extra en `pyproject.toml` (más `uv lock`). Si olvidás el lock, `setup` falla de forma visible gracias a `--locked` en vez de instalar algo sin fijar.

Cada acelerador se evalúa por separado, así que una GPU puede cumplir el umbral de uno y no el de otro (una Turing sm_7.5 recibe Triton pero no SageAttention, que exige sm_80).

### DynamicVRAM

`comfy-aimdo` (DynamicVRAM) y `comfy-kitchen` vienen **pineados en el `requirements.txt` de ComfyUI**; este gestor no los instala por separado, pero `doctor` informa de su versión.

Si un dato no se puede determinar (por ejemplo, un driver antiguo que no expone `compute_cap`), el gestor **lo dice y elige la opción conservadora** en lugar de inventar un valor.

El único nodo preinstalado es **ComfyUI-Manager**. Todo lo demás se añade a mano con `custom-nodes add`.

### Rutas no automatizadas

Este gestor solo automatiza la ruta **CUDA**. Para GPUs AMD (ROCm, DirectML, ZLUDA) o Intel (IPEX) hay que configurar el entorno manualmente; `setup` lo advierte y se detiene salvo que pases `--allow-cpu` para instalar explícitamente la variante CPU.

---

## Comandos

| Comando | Alias | Descripción |
| :--- | :--- | :--- |
| `pre-requisites` | `prereqs`, `check` | Valida `pwsh`, `uv`, `git` y conectividad. Ofrece instalar lo que falte vía Winget. |
| `probe` | `detect`, `hardware` | Detecta la GPU y guarda el perfil en `etc/config.json`. |
| `setup` | `download`, `install` | Clona ComfyUI, crea `.venv` con `uv` e instala PyTorch y los aceleradores aplicables. |
| `start` | `run` | Inicia ComfyUI con la configuración persistente. |
| `custom-nodes` | `nodes` | Gestiona nodos Git (`list`, `add`, `remove`). |
| `set <clave> [valor]` | | Guarda ajustes en `etc/config.json`. |
| `unset <clave>` | `rm` | Restablece ajustes a su valor por defecto. |
| `config` | `get` | Muestra la configuración activa. |
| `upgrade` | `update` | Actualiza ComfyUI, los nodos y los aceleradores habilitados. |
| `doctor` | | Compara el entorno real contra el perfil detectado. |
| `reset` | `uninstall` | Limpia `.venv`, la instalación y la configuración local. |
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

### `setup`
```powershell
.\comodo.ps1 setup                    # Instalación estándar
.\comodo.ps1 setup --force            # Recrea el entorno virtual desde cero
.\comodo.ps1 setup --cuda 12.6        # Fuerza una versión de CUDA concreta
.\comodo.ps1 setup --skip-opt         # Omite Triton y SageAttention
.\comodo.ps1 setup --skip-nodes       # No clona ningún nodo
.\comodo.ps1 setup --allow-cpu        # Permite instalar en modo CPU
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

Los nodos añadidos quedan registrados en `etc/config.json`, de modo que un `setup` sobre una instalación limpia los reconstruye.

### `set` / `unset`
```powershell
.\comodo.ps1 set lowvram
.\comodo.ps1 set port 8189
.\comodo.ps1 set listen 0.0.0.0
.\comodo.ps1 unset port
.\comodo.ps1 unset all                # Restablece todo el bloque runtime
```

### `reset`
```powershell
.\comodo.ps1 reset                    # Pide confirmación
.\comodo.ps1 reset --force            # Sin preguntar
.\comodo.ps1 reset --keep-models      # Preserva los modelos descargados
.\comodo.ps1 reset --keep-config      # Conserva etc/config.json
```

---

## Reproducibilidad

La capa que este gestor controla (PyTorch y los aceleradores) se declara en `pyproject.toml` y queda fijada en `uv.lock`, ambos versionados. `setup` la instala con:

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
    ├── Installer.psm1       # Clonado y aprovisionamiento (setup)
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
