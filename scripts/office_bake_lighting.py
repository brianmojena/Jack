"""Hornea con Cycles la luz de la oficina 3D en mapas de luz que la app dibuja tal cual.

Se ejecuta dentro de Blender con `Office.blend` abierto (o en segundo plano, con `-b`):

    exec(open("/ruta/a/Jack/scripts/office_bake_lighting.py").read())
    bake_all()

Hornea la luz completa que calcula el path tracing (directa, rebotes, reflejos suaves y emisión) en lo que no se mueve:
paredes, suelo, muebles y lámparas. Cada pieza recibe un mapa de UV propio («Lightmap») dentro de uno de los atlas, y el
resultado se guarda con la vista de color de la escena ya aplicada (AgX y su contraste) en `Resources/Office/Textures/Baked`.
`office_export_blender.py` exporta la sala con esos mapas y la app los dibuja sin luces ni tonos encima.

Lo que se mueve o cambia en la app (personajes, sillas, piezas de ajedrez, PC animados, pantallas, cafetera, cristales) no
se hornea: la app lo ilumina en tiempo real. Lo que se mueve tampoco hace sombra en el horneado, porque no se
queda donde está; lo demás sí (la cafetera y los PC siguen en su sitio).

Las luces del horneado están en la colección `BAKE_lighting`, junto a las paredes de rebote (`BAKE_shell_*`): cierran la sala
por los lados abiertos para que la luz rebote como en una habitación, pero no se ven en cámara ni se exportan.

Variables de entorno: `OFFICE_BAKE_SIZE` (lado de los atlas que no están en `ATLAS_SIZES`, 2048), `OFFICE_BAKE_SAMPLES`
(muestras por píxel, 64) y
`OFFICE_BAKE_CPU=1` (hornear también con la CPU, además de la gráfica).
"""
import math
import os
import re

import bpy
import numpy as np

# Junto a Office.blend: Resources/Office/Textures/Baked.
BAKED = os.path.join(os.path.dirname(os.path.abspath(bpy.data.filepath)), "Textures", "Baked") if bpy.data.filepath else ""
SIZE = int(os.environ.get("OFFICE_BAKE_SIZE", 2048))
SAMPLES = int(os.environ.get("OFFICE_BAKE_SAMPLES", 64))
# Rebotes al hornear: algo menos que en los renders (casi no se nota en la luz difusa y acorta mucho el horneado).
BOUNCES = {"max_bounces": 8, "diffuse_bounces": 4, "glossy_bounces": 3, "transmission_bounces": 4}
UV = "Lightmap"
# Separación entre islas del atlas, en píxeles. Los muebles traen miles de islas pequeñas y un margen mayor se come el atlas.
MARGIN_PIXELS = 3
# Propiedad con el atlas en que quedó horneado cada objeto; la exportación la lee.
PROP = "office_bake"
# Suelo y paredes van en su propio atlas; los muebles, en otro. La pizarra, en uno pequeño aparte: se puede volver a hornear sola
# (`bake_all(only=["board"])`) en un par de minutos.
# Los logos, la lámpara de pie (con el sofá grande, que es lo que más alumbra) y las lamparitas del techito, con muchas caras o
# vistos de cerca, en uno propio con más resolución por pieza (y rápido de volver a hornear).
ATLASES = {"room": ("Sketchfab_model", "ROOM_merged", "MIRROR_FILL", "PROP_rug", "OFFICE_soffit_left"), "board": ("PROP_chalkboard",),
           "detail": ("PROP_lang_logos", "PROP_floor_lamp", "OFFICE_lamp_", "PROP_sofa_big")}
OTHER_ATLAS = "props"
# El lado de cada atlas: el suelo y las paredes, que es lo que más se ve, con más detalle. En un M2 la gráfica hornea esta sala a
# unos 300.000 rayos por segundo: con 64 muestras, estos tamaños son unos 50 minutos; todo a 4096 con 128, unas 4 horas.
ATLAS_SIZES = {"room": 3072, "props": 2048, "board": 1024, "detail": 2048}
# Atlas a los que se añade su color sin luz (`OfficeBake_<atlas>_albedo.jpg`, junto a la sala exportada): la app multiplica el
# atlas horneado por el detalle de la textura original (la textura a resolución completa entre su versión del atlas), para que
# el suelo y el ladrillo se vean nítidos de cerca sin cambiar la luz (ver OfficeDetail.json y OfficeDetailMaterial).
ALBEDO = {"room"}
RUNTIME = os.path.join(os.path.dirname(os.path.abspath(bpy.data.filepath)), "Runtime") if bpy.data.filepath else ""
# Atlas sin reflejos: el brillo horneado se ve desde la normal de cada cara, y en los logos quedaba como vetas blancas fijas.
MATTE = {"detail"}
# Lo que la app mueve: ni se hornea ni hace sombra en el horneado.
MOVING = re.compile(r"^(CHAR_|CHESS_[wb][KQRBNP]_|CHESS_chair_|PROP_gaming_chair|PROP_shower_door)")
# Lo que la app dibuja o anima ella misma: no se hornea, pero sigue en su sitio haciendo sombra y dando luz.
# Las plantas tampoco: sus hojas son miles de caras curvas y en un atlas se ven facetadas; la app las ilumina con las panorámicas.
# El ajedrez (mesa, tablero y marco), tampoco: sus casillas están a ras de la tapa del marco y el horneado las deja negras, y
# la app las recolorea. La pantalla de la tele se llama «TV 49Zoll_Screen…» (con espacio) en Blender.
# Las sillas de la mesa de reuniones y el rack, tampoco: en el atlas compartido se veían borrosos.
APP_DRAWN = re.compile(r"^(COFFEE|PROP_pc_gamer_animation|SCREEN_|TV.49Zoll_Screen|PROP_plant|PROP_table_plant|CHESS_(table|board)|PROP_meeting_chair|PROP_server_rack)")
MIRROR_GLASS = "EspejoCuerpoEntero_Espejo_0"


def _chain(obj):
    while obj:
        yield obj
        obj = obj.parent


def _top(obj):
    return list(_chain(obj))[-1]


def _principled(material):
    if material is None or not material.use_nodes:
        return None
    return next((node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"), None)


def _see_through(obj):
    """Algún material transparente (cristal, mampara): el horneado no lo puede representar."""
    for material in obj.data.materials:
        shader = _principled(material)
        if shader is None:
            continue
        alpha, transmission = shader.inputs["Alpha"], shader.inputs["Transmission Weight"]
        if alpha.is_linked or alpha.default_value < 0.99 or transmission.is_linked or transmission.default_value > 0.01:
            return True
    return False


def _moving(obj):
    return any(MOVING.match(o.name) for o in _chain(obj))


def _app_drawn(obj):
    return any(APP_DRAWN.match(o.name) for o in _chain(obj)) \
        or any(o.animation_data and o.animation_data.action for o in _chain(obj))


def targets():
    """Los objetos que se hornean, por atlas: los mismos que exporta la sala, menos lo que la app ilumina en tiempo real."""
    found = {}
    for obj in bpy.data.objects:
        if obj.type != "MESH" or obj.hide_get() or obj.hide_viewport or obj.hide_render or not obj.data.polygons:
            continue
        if obj.name.startswith("BAKE_") or obj.name == MIRROR_GLASS or _moving(obj) or _app_drawn(obj) or _see_through(obj):
            continue
        # Las ranuras vacías se rellenan al hornear (ver `bake`); un material sin «Principled BSDF» no se sabe hornear.
        if not any(obj.data.materials) or any(m is not None and _principled(m) is None for m in obj.data.materials):
            continue
        top = _top(obj).name
        atlas = next((name for name, prefixes in ATLASES.items() if top.startswith(prefixes) or obj.name.startswith(prefixes)), OTHER_ATLAS)
        found.setdefault(atlas, []).append(obj)
    return found


def _select(objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]


def _areas(obj):
    """Superficie en el mundo y en el mapa «Lightmap» de un objeto."""
    world = obj.data.copy()
    world.transform(obj.matrix_world)
    surface = sum(polygon.area for polygon in world.polygons)
    bpy.data.meshes.remove(world)
    mesh = obj.data
    uv = np.empty(len(mesh.loops) * 2)
    mesh.uv_layers[UV].data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    starts = np.empty(len(mesh.polygons), dtype=np.int64)
    totals = np.empty(len(mesh.polygons), dtype=np.int64)
    mesh.polygons.foreach_get("loop_start", starts)
    mesh.polygons.foreach_get("loop_total", totals)
    # El siguiente vértice de cada esquina, dentro de su polígono (fórmula del área de Gauss).
    index = np.arange(len(uv))
    owner = np.repeat(np.arange(len(starts)), totals)
    following = np.where(index + 1 < starts[owner] + totals[owner], index + 1, starts[owner])
    cross = uv[:, 0] * uv[following, 1] - uv[following, 0] * uv[:, 1]
    flat = np.abs(np.bincount(owner, weights=cross, minlength=len(starts))).sum() / 2
    return surface, flat


def unwrap(objects, size):
    """Un mapa de UV «Lightmap» para todos los objetos del atlas, sin solaparse, con la misma densidad en todos.

    Las mallas compartidas se copian: cada objeto necesita su propio sitio en el atlas. El mapa de UV con que se ven las
    texturas sigue siendo el de render; «Lightmap» queda activo solo para editar y hornear.
    La densidad se iguala en el mundo, no en cada malla: los modelos importados traen escalas muy distintas.
    """
    for obj in objects:
        if obj.data.users > 1:
            obj.data = obj.data.copy()
        layers = obj.data.uv_layers
        render = next((layer.name for layer in layers if layer.active_render), None)
        if UV not in layers:
            layers.new(name=UV)
        layers.active = layers[UV]
        if render:
            layers[render].active_render = True
    _select(objects)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.0, area_weight=0.0, correct_aspect=True, scale_to_bounds=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    for obj in objects:
        surface, flat = _areas(obj)
        if flat <= 0:
            continue
        uv = np.empty(len(obj.data.loops) * 2)
        layer = obj.data.uv_layers[UV]
        layer.data.foreach_get("uv", uv)
        layer.data.foreach_set("uv", uv * math.sqrt(surface / flat))
    _select(objects)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, rotate_method="AXIS_ALIGNED", scale=True, margin_method="FRACTION", margin=MARGIN_PIXELS / size)
    bpy.ops.object.mode_set(mode="OBJECT")


def _hide_for_bake():
    """Oculta en el render lo que se mueve y los cristales; devuelve cómo estaba para dejarlo igual."""
    saved = []
    for obj in bpy.data.objects:
        if obj.type in ("MESH", "CURVE", "ARMATURE") and (_moving(obj) or obj.name == MIRROR_GLASS or (obj.type == "MESH" and _see_through(obj))):
            saved.append((obj, obj.hide_render))
            obj.hide_render = True
    return saved


def bake(atlas, objects):
    """Hornea el atlas en una imagen de 32 bits (luz lineal, sin la vista de color)."""
    size = ATLAS_SIZES.get(atlas, SIZE)
    image = bpy.data.images.get(f"OfficeBake_{atlas}_raw")
    if image is None or tuple(image.size) != (size, size):
        if image:
            bpy.data.images.remove(image)
        image = bpy.data.images.new(f"OfficeBake_{atlas}_raw", size, size, alpha=False, float_buffer=True)
    # Las caras sin material se hornean con uno gris oscuro, solo mientras dura el horneado.
    blank = bpy.data.materials.new("BAKE_blank")
    _principled(blank).inputs["Base Color"].default_value = (0.05, 0.05, 0.05, 1)
    filled = []
    for obj in objects:
        for slot in obj.material_slots:
            if slot.material is None:
                slot.material = blank
                filled.append(slot)
    materials = {slot.material for obj in objects for slot in obj.material_slots if slot.material}
    added = []
    for material in materials:
        node = material.node_tree.nodes.new("ShaderNodeTexImage")
        node.name = "BAKE_target"
        node.image = image
        material.node_tree.nodes.active = node
        added.append((material, node))
    _select(objects)
    try:
        passes = {"DIRECT", "INDIRECT", "DIFFUSE", "EMIT"} | (set() if atlas in MATTE else {"GLOSSY"})
        bpy.ops.object.bake(type="COMBINED", pass_filter=passes,
                            margin=16, margin_type="EXTEND", use_clear=True, target="IMAGE_TEXTURES")
    finally:
        for material, node in added:
            material.node_tree.nodes.remove(node)
        for slot in filled:
            slot.material = None
        bpy.data.materials.remove(blank)
    return image


def bake_albedo(atlas, objects):
    """El color sin luz del atlas, con la misma distribución: se guarda tal cual (sin vista de color ni quitar ruido)."""
    size = ATLAS_SIZES.get(atlas, SIZE)
    image = bpy.data.images.new(f"OfficeBake_{atlas}_albedo", size, size, alpha=False, float_buffer=False)
    image.colorspace_settings.name = "sRGB"
    blank = bpy.data.materials.new("BAKE_blank")
    _principled(blank).inputs["Base Color"].default_value = (0.05, 0.05, 0.05, 1)
    filled = [slot for obj in objects for slot in obj.material_slots if slot.material is None]
    for slot in filled: slot.material = blank
    materials = {slot.material for obj in objects for slot in obj.material_slots if slot.material}
    added = []
    for material in materials:
        node = material.node_tree.nodes.new("ShaderNodeTexImage"); node.name = "BAKE_target"; node.image = image
        material.node_tree.nodes.active = node; added.append((material, node))
    _select(objects)
    samples = bpy.context.scene.cycles.samples
    bpy.context.scene.cycles.samples = 4
    try:
        bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, margin=16, margin_type="EXTEND", use_clear=True, target="IMAGE_TEXTURES")
    finally:
        bpy.context.scene.cycles.samples = samples
        for material, node in added: material.node_tree.nodes.remove(node)
        for slot in filled: slot.material = None
        bpy.data.materials.remove(blank)
    path = os.path.join(RUNTIME, f"OfficeBake_{atlas}_albedo.jpg")
    image.filepath_raw = path; image.file_format = "JPEG"; image.save()
    bpy.data.images.remove(image)
    return path


def finish(atlas, image):
    """Quita el ruido (OpenImageDenoise, desde el compositor) y guarda el atlas con la vista de color de la escena."""
    scene = bpy.context.scene
    path = os.path.join(BAKED, f"OfficeBake_{atlas}.jpg")
    os.makedirs(BAKED, exist_ok=True)
    helper = bpy.data.scenes.new("BAKE_denoise")
    tree = bpy.data.node_groups.new("BAKE_denoise", "CompositorNodeTree")
    camera = bpy.data.objects.new("BAKE_denoise_camera", bpy.data.cameras.new("BAKE_denoise_camera"))
    try:
        helper.collection.objects.link(camera)
        helper.camera = camera
        helper.render.engine = "BLENDER_WORKBENCH"
        helper.render.resolution_x, helper.render.resolution_y = image.size
        helper.render.resolution_percentage = 100
        helper.render.image_settings.file_format = "JPEG"
        helper.render.image_settings.quality = 92
        helper.render.filepath = path
        helper.view_settings.view_transform = scene.view_settings.view_transform
        helper.view_settings.look = scene.view_settings.look
        helper.view_settings.exposure = scene.view_settings.exposure
        helper.view_settings.gamma = scene.view_settings.gamma
        tree.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        source = tree.nodes.new("CompositorNodeImage")
        source.image = image
        denoise = tree.nodes.new("CompositorNodeDenoise")
        output = tree.nodes.new("NodeGroupOutput")
        tree.links.new(source.outputs["Image"], denoise.inputs["Image"])
        tree.links.new(denoise.outputs["Image"], output.inputs[0])
        helper.compositing_node_group = tree
        helper.render.use_compositing = True
        with bpy.context.temp_override(scene=helper):
            bpy.ops.render.render(write_still=True, scene=helper.name)
    finally:
        bpy.data.scenes.remove(helper)
        bpy.data.node_groups.remove(tree)
        bpy.data.objects.remove(camera)
    return path


def bake_all(only=None):
    """Hornea todos los atlas, o solo los de `only` (los demás se quedan como estaban)."""
    scene = bpy.context.scene
    saved = (scene.render.engine, scene.cycles.samples, scene.cycles.device)
    scene.render.engine = "CYCLES"
    preferences = bpy.context.preferences.addons["cycles"].preferences
    preferences.compute_device_type = "METAL"
    preferences.get_devices()
    # Solo la gráfica: en los Mac con chip M, sumar la CPU (comparten memoria) hace el horneado más lento, no más rápido.
    gpu_only = os.environ.get("OFFICE_BAKE_CPU") != "1"
    for device in preferences.devices:
        device.use = device.type != "CPU" or not gpu_only
    scene.cycles.device = "GPU"
    scene.cycles.samples = SAMPLES
    bounces = {name: getattr(scene.cycles, name) for name in BOUNCES}
    for name, value in BOUNCES.items():
        setattr(scene.cycles, name, value)
    every = targets()
    groups = {atlas: objects for atlas, objects in every.items() if only is None or atlas in only}
    baked = {obj for objects in every.values() for obj in objects}
    for obj in bpy.data.objects:
        # Se borra la marca de lo que se va a hornear ahora y de lo que ya no se hornea (se quedaría con un atlas viejo).
        if PROP in obj and (only is None or obj[PROP] in only or obj not in baked or any(obj in objects for objects in groups.values())):
            del obj[PROP]
    hidden = _hide_for_bake()
    try:
        for atlas, objects in groups.items():
            unwrap(objects, ATLAS_SIZES.get(atlas, SIZE))
            image = bake(atlas, objects)
            path = finish(atlas, image)
            bpy.data.images.remove(image)
            if atlas in ALBEDO:
                print(f"Color sin luz {atlas}: {bake_albedo(atlas, objects)}", flush=True)
            for obj in objects:
                obj[PROP] = atlas
            print(f"Horneado {atlas}: {len(objects)} objetos en {path}")
    finally:
        for obj, value in hidden:
            obj.hide_render = value
        scene.render.engine, scene.cycles.samples, scene.cycles.device = saved
        for name, value in bounces.items():
            setattr(scene.cycles, name, value)
