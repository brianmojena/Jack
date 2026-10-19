"""Exporta la oficina 3D desde Blender a Resources/Office/Runtime.

Se ejecuta dentro de Blender con `Office.blend` abierto:

    exec(open("/ruta/a/Jack/scripts/office_export_blender.py").read())
    export_all()

Después, `scripts/office-assets.sh` empaqueta cada carpeta como USDZ y la valida.

Blender 5.1 pierde algunas texturas al exportar directamente a USDZ (nombres con punto, imágenes empaquetadas),
así que aquí cada pieza se exporta a una carpeta con sus texturas en disco y el empaquetado se hace aparte.
"""
import contextlib
import math
import os
import re
import shutil

import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(bpy.data.filepath))) if bpy.data.filepath else ""
STAGING = os.environ.get("OFFICE_STAGING", "/tmp/office_export")
CHARACTERS = {"REMY": "CHAR_REMY_rig", "CH31": "CHAR_CH31_rig", "GIRL": "CHAR_GIRL_rig", "DEADPOOL": "CHAR_DEADPOOL_rig", "LAMINE": "CHAR_LAMINE_rig", "FRANKLIN": "CHAR_FRANKLIN_rig"}
# Giro (en grados, sobre el eje vertical) con que se exporta cada personaje cuyo esqueleto de Mixamo viene girado de fábrica.
YAW = {"FRANKLIN": 180}
CHAIRS = {"PROP_gaming_chair_02": (0, -1), "PROP_gaming_chair_03": (0, -1), "PROP_gaming_chair": (1, 0)}
CHAIR_PULL = 1.5
# El cristal del espejo no se exporta: la app lo dibuja ella misma, con el reflejo de la sala (ver OfficeMirror).
MIRROR_GLASS = "EspejoCuerpoEntero_Espejo_0"

COMMON = dict(
    generate_preview_surface=True, export_textures_mode="NEW", overwrite_textures=True, convert_orientation=True,
    export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y", triangulate_meshes=True,
    export_uvmaps=True, export_normals=True, export_lights=False, export_cameras=False, convert_scene_units="METERS",
    selected_objects_only=True,
)


def _principled(material):
    if not material.use_nodes:
        return None
    return next((node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"), None)


@contextlib.contextmanager
def runtime_materials():
    """Ajusta, solo durante la exportación, lo que RealityKit dibuja distinto a Blender.

    - Los cristales (alfa fijo menor que 1) no se exportan: el exportador solo escribe opacidad si viene de una textura
      y, sin ella, salen opacos; con alfa casi cero no se verían de todos modos (ver `_glass`).
    - Las emisiones muy fuertes (HDR) saturan en RealityKit hasta un magenta/azul plano; se suavizan hacia blanco.
    """
    saved = []
    for material in bpy.data.materials:
        shader = _principled(material)
        if shader is None:
            continue
        color, strength = shader.inputs["Emission Color"], shader.inputs["Emission Strength"]
        if not color.is_linked and strength.default_value > 1.0:
            saved.append((material, "emission", tuple(color.default_value), strength.default_value))
            peak = max(color.default_value[:3]) or 1.0
            soft = [min(1.0, c / peak) * 0.6 + 0.4 for c in color.default_value[:3]]
            color.default_value = (*soft, 1.0)
            strength.default_value = 1.2
    try:
        yield
    finally:
        for entry in saved:
            material = entry[0]
            shader = _principled(material)
            shader.inputs["Emission Color"].default_value = entry[2]
            shader.inputs["Emission Strength"].default_value = entry[3]


def _glass(obj):
    """Un objeto cuyos materiales son todos cristal casi invisible (alfa fijo muy bajo)."""
    if obj.type != "MESH" or not obj.data.materials:
        return False
    for material in obj.data.materials:
        shader = _principled(material) if material else None
        if shader is None or shader.inputs["Alpha"].is_linked or shader.inputs["Alpha"].default_value > 0.2:
            return False
    return True


def _top(obj):
    while obj.parent:
        obj = obj.parent
    return obj


def _descendants(obj):
    found = []
    for child in obj.children:
        found.append(child)
        found += _descendants(child)
    return found


def prepare_images():
    """Cada imagen en disco, con nombre sin puntos y archivo propio, para que el exportador la encuentre."""
    textures = os.path.join(STAGING, "source_textures")
    os.makedirs(textures, exist_ok=True)
    taken = {image.name for image in bpy.data.images}
    for image in list(bpy.data.images):
        if "." in image.name and image.name not in ("Render Result", "Viewer Node"):
            new = image.name.replace(".", "_")
            while new in taken and new != image.name:
                new += "_"
            taken.discard(image.name)
            image.name = new
            taken.add(new)
    for material in bpy.data.materials:
        if not material.use_nodes:
            continue
        for node in material.node_tree.nodes:
            image = node.image if node.type == "TEX_IMAGE" else None
            if image is None or image.size[0] == 0:
                continue
            jpeg = image.name.startswith("screen_")
            image.filepath_raw = os.path.join(textures, re.sub(r"[^A-Za-z0-9_]", "_", image.name) + (".jpg" if jpeg else ".png"))
            image.file_format = "JPEG" if jpeg else "PNG"
            image.save()
    return textures


def export_room(folder):
    scene = bpy.context.scene
    scene.frame_set(1)
    saved = {}
    for name, direction in CHAIRS.items():
        chair = bpy.data.objects[name]
        saved[name] = (chair.animation_data.action if chair.animation_data else None, chair.location.copy())
        chair.animation_data.action = None
        chair.location = chair.location - Vector((direction[0], direction[1], 0)) * CHAIR_PULL  # sillas metidas
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    for obj in bpy.data.objects:
        if obj.type in ("LIGHT", "CAMERA") or _top(obj).name.startswith("CHAR_") or obj.hide_get() or obj.hide_viewport or _glass(obj) or obj.name == MIRROR_GLASS:
            continue
        try:
            obj.select_set(True)
        except RuntimeError:
            pass
    os.makedirs(folder, exist_ok=True)
    bpy.ops.wm.usd_export(filepath=os.path.join(folder, "OfficeRoom.usdc"), export_animation=False, export_materials=True,
                          export_armatures=False, use_instancing=True, **COMMON)
    for name, (action, location) in saved.items():
        chair = bpy.data.objects[name]
        chair.animation_data.action = action
        if action:
            chair.animation_data.action_slot = action.slots[0]
        chair.location = location
    scene.frame_set(1)


def export_character(key, folder, total_frames):
    scene = bpy.context.scene
    rig = bpy.data.objects[CHARACTERS[key]]
    saved = (rig.location.copy(), rig.rotation_euler.copy(), rig.animation_data.action, rig.animation_data.action_slot,
             scene.frame_start, scene.frame_end)
    rig.location = (0, 0, 0)
    rig.rotation_euler = (math.radians(90), 0, math.radians(YAW.get(key, 0)))
    action = bpy.data.actions[f"ALL_{key}"]  # línea de tiempo con todos los clips
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    scene.frame_start, scene.frame_end = 1, total_frames
    scene.frame_set(1)
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    for obj in [rig] + [o for o in _descendants(rig) if o.type == "MESH"]:
        obj.select_set(True)
    os.makedirs(folder, exist_ok=True)
    try:
        bpy.ops.wm.usd_export(filepath=os.path.join(folder, f"{key}.usdc"), export_animation=True, export_materials=True,
                              export_armatures=True, only_deform_bones=False, export_meshes=True, use_instancing=False, **COMMON)
    finally:
        rig.location, rig.rotation_euler = saved[0], saved[1]
        rig.animation_data.action, rig.animation_data.action_slot = saved[2], saved[3]
        scene.frame_start, scene.frame_end = saved[4], saved[5]
        scene.frame_set(1)


def export_all(total_frames=None):
    # Por omisión, hasta donde llegan las líneas de tiempo de los personajes (ALL_<clave>).
    if total_frames is None:
        total_frames = max(int(bpy.data.actions[f"ALL_{key}"].frame_range[1]) for key in CHARACTERS)
    if os.path.isdir(STAGING):
        shutil.rmtree(STAGING)
    os.makedirs(STAGING)
    prepare_images()
    with runtime_materials():
        export_room(os.path.join(STAGING, "OfficeRoom"))
    for key in CHARACTERS:
        export_character(key, os.path.join(STAGING, key), total_frames)
    print("Exportado en", STAGING)
