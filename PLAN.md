# Plan: Port de Anki a iOS

> Documento para el agente implementador. El repo fuente de referencia está en
> `/home/ramon/anki` (checkout del repo `ankitects/anki`, rama `main`).
> Este repo (`/home/ramon/anki_ios`) contendrá el shell iOS y el glue code.
> **No modificar `/home/ramon/anki` salvo lo indicado en la Fase 1.**

## 0. Contexto y decisiones de arquitectura (ya tomadas — no re-evaluar)

Anki desktop tiene 4 capas: `rslib/` (core Rust), `proto/` (contratos protobuf),
`ts/` (frontend Svelte servido por HTTP), `pylib/` + `qt/aqt` (Python/PyQt).

Hechos verificados en el código fuente que condicionan el diseño:

1. **El core es portable.** `rslib` ya lo consume AnkiDroid (existe
   `rslib/src/ankidroid/` con `db.rs`, `service.rs`, `error.rs` — un service
   protobuf pensado para un frontend no-Python). AnkiMobile (app oficial iOS,
   cerrada) también usa este crate. No hay nada específico de desktop en el
   scheduling/almacenamiento.
2. **El servidor web vive en Rust, no en Python.** `rslib` incluye axum
   (`rslib/Cargo.toml` líneas 48-50) y sirve las páginas Svelte de `ts/`
   (reviewer, deck options, stats, import/export, image occlusion…) vía el
   mediasrv. En desktop se accede en `http://localhost:40000/_anki/pages/`.
   **Consecuencia:** en iOS podemos arrancar ese mismo servidor en proceso y
   renderizar las páginas existentes en `WKWebView`, reutilizando casi todo el
   frontend TS sin reescribirlo.
3. **La API entre capas es protobuf sobre RPC.** `proto/anki/*.proto` define
   `backend.proto` + servicios por dominio (`scheduler.proto`, `decks.proto`,
   `notes.proto`, `sync.proto`…). El TS generado (`out/ts/lib/generated`) habla
   con el backend por POST al mismo servidor. Swift solo necesita invocar RPCs
   protobuf contra el backend Rust (por FFI directo o por HTTP local).

**Arquitectura elegida:**

```
┌────────────────────────────────────────────┐
│ App SwiftUI (shell nativo)                 │
│  - Navegación: lista de mazos, ajustes,    │
│    sync, browser básico                    │
│  - WKWebView para: reviewer, editor,       │
│    deck options, stats, image occlusion    │
├────────────────────────────────────────────┤
│ anki_ios_bridge (crate Rust, staticlib)    │
│  - expone open_backend / run_service_method│
│  - arranca el mediasrv de rslib en 127.0.0.1│
├────────────────────────────────────────────┤
│ rslib (sin cambios o mínimos)              │
└────────────────────────────────────────────┘
```

- FFI Swift↔Rust: **UniFFI no** (la API es protobuf-binaria, no necesita
  bindings tipados generados); basta una C ABI mínima de 4-5 funciones que
  pasan bytes protobuf, igual que hace `pylib/rsbridge` con PyO3 y el backend
  de AnkiDroid con JNI. Los mensajes Swift se generan con `swift-protobuf`.
- Assets web: se compilan una vez desde el repo desktop (`ts/` → `out/`) y se
  embeben en el bundle de la app; el mediasrv los sirve desde disco.

## 1. Estructura del repo objetivo

```
anki_ios/
├── PLAN.md                  (este archivo)
├── README.md
├── bridge/                  # crate Rust
│   ├── Cargo.toml           # depende de anki = { path = "../../anki/rslib" }
│   └── src/lib.rs           # C ABI, ver Fase 2
├── scripts/
│   ├── build-rust.sh        # cargo build por target iOS + lipo/xcframework
│   ├── build-web-assets.sh  # compila ts/ del repo desktop y copia a Resources
│   └── gen-swift-proto.sh   # protoc + swift-protobuf sobre ../anki/proto
├── AnkiIOS/                 # proyecto Xcode (generar con xcodegen o tuist,
│   ├── project.yml          #  NO commitear .xcodeproj a mano)
│   ├── Sources/
│   │   ├── App/             # SwiftUI: DeckListView, SettingsView, SyncView
│   │   ├── Backend/         # BackendClient.swift (wrapper de la C ABI),
│   │   │                    #  código generado por swift-protobuf
│   │   └── Web/             # AnkiWebView.swift (WKWebView + bridge JS)
│   └── Resources/web/       # assets compilados de ts/ (gitignored, se genera)
└── .gitignore
```

## 2. Fases de implementación

### Fase 1 — Crate bridge compilando para iOS (sin UI)

1. Crear `bridge/Cargo.toml`:
   - `crate-type = ["staticlib"]`
   - dependencia `anki = { path = "/home/ramon/anki/rslib" }` (ajustar a ruta
     relativa `../../anki/rslib`).
2. `bridge/src/lib.rs` — C ABI mínima (modelar sobre `pylib/rsbridge/lib.rs`
   del repo desktop, que es pequeño y hace exactamente esto para Python):
   ```rust
   extern "C" fn anki_open_backend(init_msg: *const u8, len: usize, ...) -> *mut Backend;
   extern "C" fn anki_run_method(backend: *mut Backend, service: u32, method: u32,
                                 input: *const u8, len: usize,
                                 out: *mut *mut u8, out_len: *mut usize) -> i32;
   extern "C" fn anki_free_bytes(ptr: *mut u8, len: usize);
   extern "C" fn anki_close_backend(backend: *mut Backend);
   extern "C" fn anki_start_mediasrv(backend: *mut Backend, web_root: *const c_char) -> u16; // devuelve puerto
   ```
   Estudiar cómo `pylib/rsbridge` llama a `run_service_method` y cómo
   `qt/aqt/mediasrv.py` arranca el servidor para replicar la llamada al
   equivalente Rust. El header C se escribe a mano (es diminuto) o con cbindgen.
3. Targets: `aarch64-apple-ios` (device) y `aarch64-apple-ios-sim`
   (simulador). `rustup target add` + script `build-rust.sh` que produce un
   `.xcframework` con `xcodebuild -create-xcframework`.
4. **Riesgo conocido a resolver aquí:** dependencias de rslib que no compilen
   en iOS (mirar features de `rusqlite` — debe usar `bundled`—, `reqwest`
   — necesitará `native-tls` o `rustls`—, y cualquier dep que asuma
   desktop). Si hace falta tocar `rslib/Cargo.toml` para añadir features
   condicionales `target_os = "ios"`, hacerlo en una rama del repo desktop y
   documentarlo en README. Criterio de éxito de la fase: `cargo build
   --target aarch64-apple-ios` verde + test host-side que abre un backend,
   crea una colección en un dir temporal y ejecuta un RPC (p. ej.
   `deck_tree`).

### Fase 2 — Generación de protos Swift y BackendClient

1. `scripts/gen-swift-proto.sh`: `protoc` con plugin `swift-protobuf` sobre
   `/home/ramon/anki/proto/anki/*.proto`. Commitear el código generado (los
   protos cambian poco).
2. `BackendClient.swift`: wrapper con genéricos que serializa el mensaje de
   request, llama `anki_run_method`, deserializa la response y mapea el código
   de error a un `enum AnkiError` (los errores llegan como
   `backend.proto/BackendError` cuando el rc != 0 — ver cómo lo hace
   `pylib/anki/_backend.py`).
3. Los índices `service: u32, method: u32` están definidos en el código
   generado del backend Rust (`rslib/rust_interface.rs` se genera en build;
   inspeccionar `out/` del repo desktop o el codegen en `rslib/proto_gen`).
   Generar un enum Swift con esos índices desde el mismo origen para que no
   se desincronicen — un script pequeño que parsee los .proto basta (mismo
   orden de servicios/métodos que usa el codegen Rust; verificar contra
   `pylib/anki/_backend_generated.py` en `out/`).
4. Criterio de éxito: test XCTest en simulador que abre backend, crea
   colección, añade una nota y la recupera con `search`.

### Fase 3 — Shell SwiftUI mínimo + WKWebView con el reviewer

1. `build-web-assets.sh`: en el repo desktop, `just rebuild-web` (o el recipe
   equivalente que solo construya ts/) y copiar `out/ts` + lo que el mediasrv
   espere como web root a `AnkiIOS/Resources/web/`. Inspeccionar
   `rslib/src/media/` y el código del mediasrv para saber exactamente qué
   layout de disco espera.
2. Al arrancar la app: abrir backend con la colección en
   `Application Support/`, arrancar mediasrv en puerto efímero de loopback,
   guardar el puerto.
3. `DeckListView` (SwiftUI nativo): RPC `deck_tree`, render de la lista con
   contadores due/new. Tap → pantalla de repaso.
4. Pantalla de repaso: `WKWebView` cargando la página del reviewer del
   mediasrv (misma URL relativa que usa desktop, ver `ts/reviewer/`).
   Botonera de respuestas: decidir tras inspeccionar si la página del
   reviewer de `ts/` es autosuficiente o si desktop pinta los botones en Qt —
   si es lo segundo, botonera nativa SwiftUI que llama a los RPCs de
   scheduler (`scheduler.proto`: `get_queued_cards`, `answer_card`).
5. Criterio de éxito: repasar un mazo real de principio a fin en el
   simulador, incluyendo audio/imágenes (media servida por mediasrv).

### Fase 4 — Sync

1. RPCs de `sync.proto` (`sync_login`, `sync_collection`, `full_upload/download`,
   media sync). La lógica completa ya está en rslib; solo hace falta UI de
   login y progreso (los RPCs de progreso existen, ver `progress.rs`).
2. Probar contra AnkiWeb con una cuenta de test. Manejar el caso
   full-sync-required.
3. Criterio de éxito: sync bidireccional con AnkiWeb de colección + media.

### Fase 5 — Resto de pantallas (por prioridad)

1. Editor de notas (WKWebView, `ts/` editor — verificar estado tras el commit
   `643187a05 "Shift editor control to TypeScript"` del repo desktop, que
   movió el control del editor a TS: buena noticia para nosotros).
2. Deck options, Stats, Card templates → páginas web existentes en WKWebView.
3. Browser: versión nativa simplificada (lista + search RPC), no portar la
   tabla Qt.
4. Ciclo de vida iOS: cerrar/checkpoint de la colección en
   `scenePhase == .background`, backup automático (rslib ya trae backups).

## 3. Reglas para el implementador

- **Reutilizar, no reescribir**: ante cualquier funcionalidad, primero buscar
  el RPC en `proto/anki/` y la página en `ts/`. Solo escribir Swift para
  navegación, y lógica que en desktop viva en `qt/aqt` (Python).
- Referencias canónicas para cada duda de integración:
  `pylib/rsbridge/lib.rs` (FFI), `pylib/anki/_backend.py` (dispatch de RPCs y
  errores), `qt/aqt/mediasrv.py` (cómo consume desktop el servidor web),
  `rslib/src/ankidroid/` (precedente de frontend no-Python).
- No commitear artefactos generados pesados (assets web, .xcframework);
  gitignore + scripts reproducibles.
- Trabajar fase a fase; cada fase tiene criterio de éxito explícito y debe
  quedar verde antes de la siguiente. Commits pequeños por fase.
- macOS + Xcode son necesarios desde la Fase 1 (paso 3) en adelante; los
  pasos 1-2 de la Fase 1 se pueden validar en Linux con `cargo check`
  (sin target iOS) para adelantar trabajo.

## 4. Riesgos abiertos (investigar en la fase correspondiente)

| Riesgo | Fase | Mitigación |
|---|---|---|
| Deps de rslib que no compilen en iOS (TLS, sqlite, procesos) | 1 | Features condicionales; rama en repo desktop |
| El mediasrv puede asumir cosas de desktop (rutas, CORS, auth token) | 3 | Leer `rslib` mediasrv antes de diseñar el arranque |
| Páginas ts/ con dependencias de la bridge JS de Qt (`qt/aqt/data/web`) | 3/5 | Shim JS en WKWebView que emule esa bridge |
| App Store: ¿conflicto de marca con AnkiMobile (app oficial de pago)? | — | Decisión del usuario: renombrar antes de publicar; AGPL obliga a publicar fuente |
