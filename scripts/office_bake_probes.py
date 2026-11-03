"""Renderiza con Cycles las panorámicas de luz de la oficina 3D: la luz de lo que se mueve en la app.

Se ejecuta dentro de Blender con `Office.blend` abierto (o en segundo plano, con `-b`):

    exec(open("/ruta/a/Jack/scripts/office_bake_probes.py").read())
    bake_probes()

La sala lleva su luz horneada (`office_bake_lighting.py`), pero lo que se mueve (personajes, sillas, piezas) no se puede
hornear. En su lugar, cada zona de la sala tiene una panorámica HDR de 360° hecha desde la altura media de un personaje con la
misma luz; la app la usa como luz ambiental y, al caminar, mezcla las dos más cercanas. Así no hace falta ninguna luz en tiempo
real. Las zonas tienen que coincidir con `OfficeStage.probeZones`.

En las panorámicas se ven las propias luces (paneles, lámparas, focos): sin ellas solo llegaría el rebote y los personajes
quedarían planos. También se ven el techo y las paredes de rebote, para que la sala esté cerrada. Los personajes se ocultan
para que no se tapen la luz a sí mismos.
"""
import math
import os

import bpy

RUNTIME = os.path.join(os.path.dirname(os.path.abspath(bpy.data.filepath)), "Runtime") if bpy.data.filepath else ""
# Punto del suelo (x, y) de cada zona; la altura es la media de un personaje (miden unas 6 unidades).
# En sitios despejados: una mesa o un escritorio pegados a la cámara ocuparían media panorámica.
PROBES = {"pcs": (3.3, -1.5), "meeting": (8.0, -14.0), "mac": (1.5, -9.0), "lounge": (-1.0, -0.5), "sofa": (6.0, -17.5),
          "chess": (18.8, -15.0), "rack": (18.0, 0.0)}
HEIGHT = 3.0
# El techo del modelo, oculto en el visor y en la app.
CEILING = "Object_200"
SIZE = (1024, 512)
SAMPLES = int(os.environ.get("OFFICE_PROBE_SAMPLES", 128))


def _top(obj):
    while obj.parent:
        obj = obj.parent
    return obj


def bake_probes():
    scene = bpy.context.scene
    data = bpy.data.cameras.new("BAKE_probe_camera")
    data.type = "PANO"
    data.panorama_type = "EQUIRECTANGULAR"
    camera = bpy.data.objects.new("BAKE_probe_camera", data)
    scene.collection.objects.link(camera)
    # Mirando a +y de Blender, que es -z en RealityKit: el centro de cada panorámica es el «delante» de la app.
    camera.rotation_euler = (math.radians(90), 0, 0)
    changed = []
    for obj in bpy.data.objects:
        if _top(obj).name.startswith("CHAR_") and not obj.hide_render:
            changed.append((obj, "hide_render", False))
            obj.hide_render = True
        # Las luces y la sala cerrada (techo y paredes de rebote, que en la app no se ven) sí cuentan en la panorámica.
        elif (obj.type == "LIGHT" and obj.name.startswith("BAKE_") or obj.name.startswith("BAKE_shell") or obj.name == CEILING) \
                and not obj.visible_camera:
            changed.append((obj, "visible_camera", False))
            obj.visible_camera = True
    render, settings = scene.render, scene.render.image_settings
    saved = (scene.camera, render.engine, render.resolution_x, render.resolution_y, render.resolution_percentage, scene.cycles.samples,
             settings.file_format, settings.color_depth)
    scene.camera = camera
    render.engine = "CYCLES"
    render.resolution_x, render.resolution_y = SIZE
    render.resolution_percentage = 100
    scene.cycles.samples = SAMPLES
    settings.file_format = "OPEN_EXR"
    settings.color_depth = "16"
    try:
        for name, (x, y) in PROBES.items():
            camera.location = (x, y, HEIGHT)
            bpy.ops.render.render()
            path = os.path.join(RUNTIME, f"OfficeProbe_{name}.exr")
            bpy.data.images["Render Result"].save_render(path)
            print("Panorámica", name, path)
    finally:
        for obj, attribute, value in changed:
            setattr(obj, attribute, value)
        (scene.camera, render.engine, render.resolution_x, render.resolution_y, render.resolution_percentage, scene.cycles.samples,
         settings.file_format, settings.color_depth) = saved
        bpy.data.objects.remove(camera)
        bpy.data.cameras.remove(data)
