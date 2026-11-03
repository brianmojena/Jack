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
# Los PC de los escritorios traen su propia animación (ventiladores y luces): la sala se exporta con ella, en estos fotogramas.
PC_FRAMES = (0, 30)
# La cafetera tiene su vapor animado: va aparte (OfficeCoffee.usdz) y la app la pone en el marcador PROP_coffee_spot.
COFFEE = "COFFEE"

# Aligerado al exportar: cuánto se conserva (ratio de «Decimate») de los triángulos de las mallas grandes de cada pieza. Lo que
# hace pesada la escena son pocas piezas con cientos de miles de triángulos que desde la cámara de la oficina no se distinguen:
# aquí se recortan solo en la exportación y el .blend queda intacto. Las mallas pequeñas (pantallas, cristales, caras) no se tocan.
LIGHT_RATIOS = {
    "WORKSTATION_01": 0.35, "WORKSTATION_02": 0.35, "WORKSTATION_03": 0.35,
    "COFFEE": 0.2, "PROP_lang_logos": 0.5, "PROP_sofa": 0.5,
    "PROP_plant_big": 0.5, "PROP_plant_big_2": 0.5, "PROP_table_plant": 0.3,
    "CHAR_LAMINE_rig": 0.4,
}
# Los tramos de nombre de las mallas que no se aligeran nunca (el vapor es una malla animada y las caras se ven de cerca).
LIGHT_KEEP = ("steam", "face", "glass", "screen")
LIGHT_MIN_TRIS = 1500
# Las botas de Lamine pesan 36.000 triángulos y apenas se ven.
LIGHT_MESH_RATIOS = {"CHAR_LAMINE_boot": 0.2}

# La luz horneada (scripts/office_bake_lighting.py): el atlas de cada objeto, su mapa de UV y la carpeta de los atlas.
BAKED_PROP = "office_bake"
BAKED_UV = "Lightmap"
BAKED_PREFIX = "OfficeBake_"

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


def _baked_material(atlas, path):
    """El material con que se exporta lo horneado: negro, mate y con el atlas como emisión. La app lo reconoce por eso y
    lo dibuja sin luces ni tonos encima (ver OfficeStage.applyBakedLighting)."""
    material = bpy.data.materials.new(f"{BAKED_PREFIX}{atlas}")
    material.use_nodes = True
    shader = _principled(material)
    shader.inputs["Base Color"].default_value = (0, 0, 0, 1)
    shader.inputs["Metallic"].default_value = 0.0
    shader.inputs["Roughness"].default_value = 1.0
    shader.inputs["Emission Strength"].default_value = 1.0
    node = material.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = bpy.data.images.load(path, check_existing=True)
    node.image.name = f"{BAKED_PREFIX}{atlas}"
    material.node_tree.links.new(node.outputs["Color"], shader.inputs["Emission Color"])
    return material


def _baked(obj):
    return obj.type == "MESH" and obj.get(BAKED_PROP) and BAKED_UV in obj.data.uv_layers


@contextlib.contextmanager
def baked_lighting():
    """Pone, solo durante la exportación, la luz horneada en lo que la tiene: su atlas como único material y su mapa de UV
    «Lightmap» como el de render (el exportador lo llama `st`). Sin atlas en disco, la sala se exporta como siempre."""
    folder = os.path.join(os.path.dirname(os.path.abspath(bpy.data.filepath)), "Textures", "Baked")
    materials, saved, stripped = {}, [], {}
    for obj in bpy.data.objects:
        if not _baked(obj):
            continue
        atlas = obj[BAKED_PROP]
        path = os.path.join(folder, f"{BAKED_PREFIX}{atlas}.jpg")
        if not os.path.isfile(path):
            continue
        if atlas not in materials:
            materials[atlas] = _baked_material(atlas, path)
        layers = obj.data.uv_layers
        render = next((layer.name for layer in layers if layer.active_render), None)
        saved.append((obj, [slot.material for slot in obj.material_slots], render, obj.data))
        layers[BAKED_UV].active_render = True
        for slot in obj.material_slots:
            slot.material = materials[atlas]
        # Solo el mapa del atlas: con otro más, RealityKit puede dar a los shaders propios (el detalle del suelo y el ladrillo)
        # el mapa equivocado como `uv0`. Se exporta una copia de la malla sin los demás.
        if len(layers) > 1:
            if obj.data.name not in stripped:
                copy = obj.data.copy()
                for layer in [layer for layer in copy.uv_layers if layer.name != BAKED_UV]:
                    copy.uv_layers.remove(layer)
                stripped[obj.data.name] = copy
            obj.data = stripped[obj.data.name]
    try:
        yield
    finally:
        for obj, previous, render, data in saved:
            obj.data = data
            for slot, material in zip(obj.material_slots, previous):
                slot.material = material
            if render:
                obj.data.uv_layers[render].active_render = True
        for copy in stripped.values():
            bpy.data.meshes.remove(copy)
        for material in materials.values():
            image = material.node_tree.nodes["Image Texture"].image
            bpy.data.materials.remove(material)
            bpy.data.images.remove(image)


def _triangles(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


@contextlib.contextmanager
def lightweight_meshes():
    """Aligera durante la exportación las mallas grandes de `LIGHT_RATIOS` con un modificador «Decimate» (puesto el primero de
    la pila, antes del esqueleto, para no tocar los pesos), y lo deja todo como estaba al terminar.

    El exportador de USD escribe las mallas con esqueleto sin evaluar sus modificadores: a esas se les aplica el «Decimate» sobre
    una copia de la malla, que sustituye a la original solo durante la exportación (los pesos viajan con la malla).
    """
    added, swapped = [], []
    for obj in bpy.data.objects:
        # Lo horneado no se aligera: el «Decimate» juntaría caras de islas distintas del atlas.
        if obj.type != "MESH" or _triangles(obj) < LIGHT_MIN_TRIS or any(word in obj.name.lower() for word in LIGHT_KEEP) or _baked(obj):
            continue
        ratio = LIGHT_MESH_RATIOS.get(obj.name, LIGHT_RATIOS.get(_top(obj).name))
        if ratio is None:
            continue
        modifier = obj.modifiers.new("light_decimate", "DECIMATE")
        modifier.decimate_type = "COLLAPSE"
        modifier.ratio = ratio
        obj.modifiers.move(len(obj.modifiers) - 1, 0)
        if any(m.type == "ARMATURE" for m in obj.modifiers):
            original = obj.data
            obj.data = original.copy()
            with bpy.context.temp_override(object=obj, active_object=obj, selected_objects=[obj]):
                bpy.ops.object.modifier_apply(modifier=modifier.name)
            swapped.append((obj, original))
        else:
            added.append((obj, modifier.name))
    try:
        yield
    finally:
        for obj, name in added:
            obj.modifiers.remove(obj.modifiers[name])
        for obj, original in swapped:
            copy = obj.data
            obj.data = original
            bpy.data.meshes.remove(copy)


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
            jpeg = image.name.startswith(("screen_", BAKED_PREFIX))
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
        # `BAKE_*` es solo para el horneado: las luces y las paredes de rebote de los lados abiertos. Lo oculto en el render
        # tampoco va: no está en la luz horneada y quedaría a oscuras sobre ella (los recortes viejos de la pared del espejo).
        if obj.type in ("LIGHT", "CAMERA") or _top(obj).name.startswith("CHAR_") or _top(obj).name == COFFEE or obj.hide_get() or obj.hide_viewport \
                or _glass(obj) or obj.name == MIRROR_GLASS or obj.name.startswith("BAKE_") or obj.hide_render:
            continue
        try:
            obj.select_set(True)
        except RuntimeError:
            pass
    os.makedirs(folder, exist_ok=True)
    # Las sillas van sin animación (las mueve la app); lo único animado que queda en la sala son los PC.
    frames = (scene.frame_start, scene.frame_end)
    scene.frame_start, scene.frame_end = PC_FRAMES
    try:
        bpy.ops.wm.usd_export(filepath=os.path.join(folder, "OfficeRoom.usdc"), export_animation=True, export_materials=True,
                              export_armatures=False, use_instancing=True, **COMMON)
    finally:
        scene.frame_start, scene.frame_end = frames
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


def export_coffee(folder):
    """La cafetera con su animación, en el origen (la app la coloca); `False` si la sala no la tiene."""
    root = bpy.data.objects.get(COFFEE)
    if root is None:
        return False
    scene = bpy.context.scene
    animated = [o for o in _descendants(root) if o.animation_data and o.animation_data.action]
    end = max((int(o.animation_data.action.frame_range[1]) for o in animated), default=1)
    saved = (root.location.copy(), scene.frame_start, scene.frame_end)
    root.location = (0, 0, 0)
    scene.frame_start, scene.frame_end = 1, end
    scene.frame_set(1)
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    for obj in [root] + _descendants(root):
        obj.select_set(True)
    os.makedirs(folder, exist_ok=True)
    try:
        bpy.ops.wm.usd_export(filepath=os.path.join(folder, "OfficeCoffee.usdc"), export_animation=True, export_materials=True,
                              export_armatures=False, use_instancing=False, **COMMON)
    finally:
        root.location = saved[0]
        scene.frame_start, scene.frame_end = saved[1], saved[2]
        scene.frame_set(1)
    return True


def export_all(total_frames=None):
    # Por omisión, hasta donde llegan las líneas de tiempo de los personajes (ALL_<clave>).
    if total_frames is None:
        total_frames = max(int(bpy.data.actions[f"ALL_{key}"].frame_range[1]) for key in CHARACTERS)
    if os.path.isdir(STAGING):
        shutil.rmtree(STAGING)
    os.makedirs(STAGING)
    with baked_lighting():
        prepare_images()
        with runtime_materials(), lightweight_meshes():
            export_room(os.path.join(STAGING, "OfficeRoom"))
            export_coffee(os.path.join(STAGING, "OfficeCoffee"))
            for key in CHARACTERS:
                export_character(key, os.path.join(STAGING, key), total_frames)
    print("Exportado en", STAGING)
