# Stellar Code: entrenar Gemma 4 E2B para Jack

Aquí está la preparación que faltaba: datos comprobados, notebook de Colab, QLoRA,
checkpoints en Drive, exportación GGUF e importación con herramientas en Ollama.
El modelo a entrenar es `unsloth/gemma-4-E2B-it`, una distribución compatible del
Gemma 4 E2B instruct de Google. `gemma4:e2b` es el nombre de Ollama y no se usa
como identificador de Hugging Face.

## Lo que puedes abrir ahora

1. Entra a <https://colab.research.google.com/> y elige **Subir notebook**.
2. Abre `Stellar_Gemma4_E2B_Colab.ipynb`.
3. Selecciona **Entorno de ejecución → Cambiar tipo → GPU** (T4 o superior).
4. Ejecuta las celdas en orden y sube `stellar-colab.zip` al selector del notebook.
5. Autoriza el montaje de tu Drive. Los datos del paquete son sintéticos; no contiene el código de Jack ni conversaciones personales.
6. La primera ejecución hace 10 pasos con `SMOKE_TEST=True`. Si termina, pon
   `SMOKE_TEST=False` y vuelve a ejecutar la celda de entrenamiento para una época completa.
7. Ejecuta la celda de exportación y descarga desde Drive el GGUF de lenguaje y
   su `Modelfile`. El directorio `adapter` queda guardado aunque falle la exportación.

La receta parte de las instrucciones oficiales de Unsloth consultadas el
6 de octubre de 2026. El entrenamiento CUDA y la conversión se ejecutan en Colab;
la validación local del paquete no demuestra que esas fases ya se hayan ejecutado.

## Datos y objetivo

Las ocho familias son: corregir bugs, añadir funciones, responder sobre el
proyecto, crear archivos, renombrar, ejecutar y reportar tests, buscar TODO/FIXME
y conversar sin herramientas. Hay ejemplos en español e inglés. `stellar_env.py`
conserva el entorno/oráculo legado del paquete; no implementa el prompt Normal
actual, la carga acotada de instrucciones, el presupuesto de contexto ni el listado
Normal de `Sources/JackCore/StellarCode.swift`.

Cada trayectoria oracle ejecuta herramientas reales en un proyecto temporal y
comprueba el resultado. Los tests fallidos de diagnóstico son contexto válido.
Se eliminan tareas repetidas y todas las soluciones de una misma tarea, incluidas
las del teacher opcional, quedan en la misma partición. La validación se estratifica
por familia. Los nombres del benchmark salen de los pools de evaluación reservados.
Las plantillas de tareas siguen siendo parecidas: el benchmark mide este conjunto
de habilidades y no garantiza mejora en repositorios grandes o tareas arbitrarias.
`eval_fixtures/multiturn_instructions.json` y `eval_multiturn.py` preparan un scorer
offline para un transcript de tres turnos: exige citas con línea, detecta ediciones
prohibidas en `docs/`, comprueba que instrucciones anidadas lleguen antes de editar y
rechaza afirmaciones de tests sin llamada y resultado exitoso. Las pruebas incluyen un
transcript positivo y casos negativos mutados. El scorer solo puntúa trazas suministradas;
no ejecuta inferencia y no mide una mejora del entrenamiento ni la calidad general del modelo.

La plantilla de herramientas se descarga del repositorio oficial de Google y se
fija por revisión para cada entrenamiento. Se comprueba que conserve todas las
llamadas y resultados. Se entrenan las llamadas nativas, su token de cesión y las
respuestas del asistente; se enmascaran sistema, usuario y cuerpos de resultados.
Las trayectorias demasiado largas se excluyen enteras, nunca se truncan; si supera
el 10% de una partición el entrenamiento se detiene para ajustar el contexto.

## Recuperar una sesión de Colab

Los checkpoints están en `MyDrive/JackTraining/stellar-e2b-v1/checkpoint-*`;
la prueba corta usa `stellar-e2b-v1-smoke`. Vuelve a subir el paquete, monta Drive,
instala las dependencias y usa `RESUME=True` con el mismo modo, `RUN_NAME` y contexto.
Los datos, la revisión del modelo y los parámetros deben coincidir.
Para otro experimento cambia `RUN_NAME`. El programa evita sobrescribir una ejecución anterior.

Si una celda falla, el notebook actualizado muestra el error del proceso, no solo
`CalledProcessError`. La salida completa se guarda en Drive junto a la carpeta
del modelo: `stellar-e2b-v1-train.log` o `stellar-e2b-v1-smoke-train.log`.
Copia las últimas líneas de ese registro para diagnosticar la causa concreta.
Cambiar de smoke a completo selecciona otra carpeta; no reanuda la prueba corta.
Un fallo puede dejar `run_config.json` antes del primer checkpoint: en ese caso
`RESUME=True` no puede continuar; conserva el registro y usa un `RUN_NAME` nuevo
después de resolver el error original.

Si ya terminó y solo falta el GGUF, ejecuta `export_colab.py --output RUTA_DE_LA_EJECUCION`
en Colab. No hace falta reentrenar. Se exporta **Q8_0**; la receta oficial E2B
consultada limita las opciones a Q8_0/F16/BF16. No se promete que Q4_K_M esté disponible.
La exportación puede necesitar más RAM/disco que el entrenamiento.

## Importar y medir en el Mac

Desde esta carpeta, con Ollama actualizado y en ejecución:

```bash
jack-progress run --title "Importar Stellar Gemma" --kind model -- python3 ollama_import.py /ruta/modelo.Q8_0.gguf
ollama show stellar-gemma:e2b
```

`ollama show` debe listar la capacidad `tools`. El importador usa `RENDERER gemma4`
y `PARSER gemma4`, además de los tokens de parada de Gemma. Así Ollama interpreta
las llamadas a las seis herramientas de Stellar. No modifica `gemma4:e2b`.
Este paquete ajusta texto/herramientas y exporta el GGUF de lenguaje; no prepara
una nueva integración de imágenes o audio en Jack.

Compara las mismas tareas, parámetros y repeticiones:

```bash
jack-progress run --title "Evaluar Gemma original" -- python3 bench.py run --model gemma4:e2b --per-family 8 --repeat 2 --options '{"temperature":0,"seed":3407}' --out runs/base
jack-progress run --title "Evaluar Gemma entrenado" -- python3 bench.py run --model stellar-gemma:e2b --per-family 8 --repeat 2 --options '{"temperature":0,"seed":3407}' --out runs/finetuned
python3 bench.py compare runs/base runs/finetuned
```

Si se interrumpe una evaluación, repite el mismo comando con `--resume`.
Se rechaza mezclar modelos/opciones/tareas diferentes en una carpeta.
Comprueba éxito por familia, llamadas mal formadas, errores, tareas en las que no
actuó, pasos y latencia. Una pérdida menor en Colab es evidencia auxiliar;
elige el modelo entrenado en Stellar Code de Jack después de comparar su comportamiento.
Estos benchmarks ejecutan comandos y ediciones generados por el modelo en carpetas
temporales, como el agente de Jack; no constituyen un sandbox de seguridad.

## Regenerar o ampliar los datos

No necesitas librerías de ML en el Mac para preparar el paquete:

```bash
jack-progress run --title "Generar datos de Stellar" -- python3 make_dataset.py --per-family 150 --out data
python3 data_utils.py data
python3 -m unittest discover -p 'test_*.py'
python3 prepare_colab.py
```

Teacher opcional, únicamente si tienes ese modelo instalado en Ollama:

```bash
jack-progress run --title "Añadir soluciones teacher" -- python3 make_dataset.py --per-family 150 --teacher gemma4:26b --teacher-per-family 40 --out data-teacher
```

Solo se retienen soluciones verificadas sin errores de herramientas ni servidor.
Para empaquetar un conjunto diferente, sustituye `data` por el conjunto validado y
vuelve a ejecutar `prepare_colab.py`. El notebook comprueba los hashes del manifiesto.

## Archivos

- `data/train.jsonl`, `valid.jsonl`, `manifest.json`: ejemplos y conteos/hashes.
- `train_colab.py`, `gemma_format.py`: entrenamiento y etiquetas verificables.
- `export_colab.py`, `ollama_import.py`: exportación y registro local.
- `Stellar_Gemma4_E2B_Colab.ipynb`, `stellar-colab.zip`: notebook y paquete portable.
- `bench.py`, `tasks.py`, `stellar_env.py`, `runner.py`: evaluación y entorno real de herramientas.
- `test_training.py`, `eval_multiturn.py`, `eval_fixtures/`: regresiones locales sin GPU y scorer preparado para revisar transcripts de varios turnos.

## Referencias verificadas

- [Gemma 4 E2B instruct de Google](https://huggingface.co/google/gemma-4-E2B-it)
- [Guía de entrenamiento de Unsloth](https://unsloth.ai/docs/models/gemma-4/train)
- [Notebook oficial E2B de texto](https://github.com/unslothai/notebooks/blob/main/nb/Gemma4_(E2B)-Text.ipynb)
- [Plantilla canónica de Google](https://huggingface.co/google/gemma-4-E2B-it/blob/main/chat_template.jinja)
- [Importar GGUF en Ollama](https://docs.ollama.com/import)
- [Directivas renderer/parser de Ollama](https://github.com/ollama/ollama/blob/main/parser/parser.go)
