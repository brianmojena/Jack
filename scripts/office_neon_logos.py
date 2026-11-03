"""Convierte los logos de lenguajes de la pared en letreros de neón LED: tubos finos de luz que siguen la silueta de cada logo,
como un letrero de neón de verdad (y como el `</>` de la pared del fondo).

Se ejecuta dentro de Blender con `Office.blend` abierto:

    exec(open("/ruta/a/Jack/scripts/office_neon_logos.py").read())
    make_neon_logos()

Las siluetas salen de `Resources/Office/Logos/neon/*.svg` (Simple Icons, CC0): una sola forma con sus huecos, así que el tubo
recorre solo el contorno y los huecos principales, sin las rayas de los degradados y piezas de los logos a color. Java no
tiene silueta de la taza en Simple Icons: se dibuja aquí con trazos (taza, borde, asa, plato y vapor).

Los logos macizos (`PROP_lang_logos_merged_0`) quedan ocultos, no se borran. Los tubos son hijos de `PROP_lang_logos`, así que
se hornean con los logos (atlas «detail») y su luz tiñe la pared en el horneado de la sala.
"""
import math
import os

import bpy
from mathutils import Matrix, Vector

LOGOS = "PROP_lang_logos_merged_0"
PREFIX = "PROP_lang_logos_neon_"
SVGS = os.path.join(os.path.dirname(os.path.abspath(bpy.data.filepath)), "Logos", "neon") if bpy.data.filepath else ""
# Centro de cada logo en la pared (y, z de Blender); dos filas de tres, mirando a la sala (+x).
CELLS = {"swift": (-13.6, 8.35), "python": (-11.6, 8.35), "typescript": (-9.6, 8.35),
         "java": (-13.6, 6.45), "svelte": (-11.6, 6.45), "kotlin": (-9.6, 6.45)}
# Donde van los tubos: a unos 7 cm de la pared (su cara está en x = -5.971), como un letrero sobre separadores.
FACE_X = -5.90
# El lado del cuadrado donde cabe cada logo, el grosor del tubo y su brillo (unidades de la sala; un personaje mide unas 6).
SIZE = 1.3
TUBE = 0.03
STRENGTH = 2.6
# La luz que dan los neones a la pared: un emisor invisible a cámara pegado a cada tubo, mucho más fuerte (el tubo visible
# se queda en un brillo que deja ver su color; con todo el brillo en él se vería blanco).
GLOW = 38.0
GLOW_PREFIX = "BAKE_neon_glow_"
# Los colores de cada logo, en orden de `material_index` de sus trazos (Java: la taza y el vapor).
COLORS = {"swift": [(1.0, 0.32, 0.16)], "python": [(1.0, 0.8, 0.12)], "typescript": [(0.12, 0.48, 1.0)],
          "java": [(0.05, 0.82, 1.0), (1.0, 0.36, 0.06)], "svelte": [(1.0, 0.06, 0.05)], "kotlin": [(0.56, 0.32, 1.0)]}


def _neon_material(name, color):
    """Un tubo encendido: emite su color saturado; el vidrio, oscuro de ese tono, para que la luz de la sala no lo lave."""
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.use_nodes = True
    shader = next(node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
    shader.inputs["Base Color"].default_value = (*[0.35 * c for c in color], 1)
    shader.inputs["Emission Color"].default_value = (*color, 1)
    shader.inputs["Emission Strength"].default_value = STRENGTH
    shader.inputs["Roughness"].default_value = 0.3
    return material


def _glow_material(name, color):
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.use_nodes = True
    tree = material.node_tree
    tree.nodes.clear()
    emission = tree.nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = (*color, 1)
    emission.inputs["Strength"].default_value = GLOW
    tree.links.new(emission.outputs[0], tree.nodes.new("ShaderNodeOutputMaterial").inputs[0])
    return material


def _smooth(points, steps=5):
    """Los puntos de control como una curva suave (Catmull-Rom), en una lista de puntos."""
    out = []
    padded = [points[0]] + points + [points[-1]]
    for i in range(1, len(padded) - 2):
        p0, p1, p2, p3 = (Vector(padded[i + k]) for k in (-1, 0, 1, 2))
        for s in range(steps):
            t = s / steps
            out.append(0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3))
    out.append(Vector(points[-1]))
    return [(p.x, p.y) for p in out]


def _ellipse(cx, cy, rx, ry, start=0.0, end=2 * math.pi, steps=28):
    return [(cx + rx * math.cos(start + (end - start) * i / steps), cy + ry * math.sin(start + (end - start) * i / steps)) for i in range(steps + 1)]


def _java():
    """La taza de Java en un cuadrado de 24 (y hacia arriba): taza, borde, asa y plato (azul) y dos hilos de vapor (naranja)."""
    data = bpy.data.curves.new(f"{PREFIX}java", "CURVE")
    strokes = [
        (_smooth([(5.6, 13.2), (6.3, 8.6), (8.0, 5.4), (10.5, 4.4), (13.5, 4.4), (16.0, 5.4), (17.7, 8.6), (18.4, 13.2)]), 0, False),
        (_ellipse(12, 13.2, 6.4, 1.0), 0, True),
        (_smooth([(18.1, 11.6), (20.6, 11.4), (21.4, 9.4), (20.0, 7.6), (17.2, 7.0)]), 0, False),
        (_ellipse(12, 2.6, 9.2, 1.3, math.pi * 1.05, math.pi * 1.95), 0, False),
        (_smooth([(10.4, 15.2), (9.4, 16.8), (10.6, 18.4), (11.6, 20.0), (10.6, 21.8)]), 1, False),
        (_smooth([(13.6, 15.2), (12.8, 16.6), (13.9, 18.0), (14.6, 19.4), (13.8, 20.8)]), 1, False),
    ]
    for points, index, closed in strokes:
        spline = data.splines.new("POLY")
        spline.points.add(len(points) - 1)
        for point, (x, y) in zip(spline.points, points):
            point.co = (x, y, 0, 1)
        spline.use_cyclic_u = closed
        spline.material_index = index
    obj = bpy.data.objects.new(f"{PREFIX}java", data)
    bpy.context.scene.collection.objects.link(obj)
    # Sin materiales todavía, Blender deja el de cada trazo en 0: se guarda aparte y se pone al final.
    obj["neon_colors"] = [index for _, index, _ in strokes]
    return obj


def _svg(name):
    """La silueta del SVG como una sola curva, en su plano XY."""
    before = set(bpy.data.objects)
    bpy.ops.import_curve.svg(filepath=os.path.join(SVGS, f"{name}.svg"))
    made = [o for o in bpy.data.objects if o not in before and o.type == "CURVE"]
    for obj in made:
        obj.data.transform(obj.matrix_world)
        obj.matrix_world = Matrix.Identity(4)
    if len(made) > 1:
        with bpy.context.temp_override(active_object=made[0], selected_editable_objects=made, object=made[0]):
            bpy.ops.object.join()
    obj = made[0]
    obj.name = f"{PREFIX}{name}"
    return obj


def _points(curve):
    for spline in curve.splines:
        for point in (spline.bezier_points if spline.type == "BEZIER" else spline.points):
            yield point.co.xy


def make_neon_logos():
    source = bpy.data.objects[LOGOS]
    parent = source.parent
    collection = source.users_collection[0]
    for obj in [o for o in bpy.data.objects if o.name.startswith((PREFIX, GLOW_PREFIX))]:
        data = obj.data
        bpy.data.objects.remove(obj)
        if data is not None and data.users == 0:
            (bpy.data.meshes if isinstance(data, bpy.types.Mesh) else bpy.data.curves).remove(data)
    # Del plano XY del dibujo a la pared: x del dibujo → y de la sala, y del dibujo → z (arriba), mirando a +x.
    turn = Matrix(((0, 0, 1, 0), (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
    made = []
    for name, (y, z) in CELLS.items():
        obj = _java() if name == "java" else _svg(name)
        for collection_ in list(obj.users_collection):
            collection_.objects.unlink(obj)
        collection.objects.link(obj)
        curve = obj.data
        curve.dimensions = "3D"
        points = list(_points(curve))
        low = Vector((min(p.x for p in points), min(p.y for p in points)))
        high = Vector((max(p.x for p in points), max(p.y for p in points)))
        scale = SIZE / max(high.x - low.x, high.y - low.y)
        centre = (low + high) / 2
        curve.transform(Matrix.Translation((FACE_X, y, z)) @ turn @ Matrix.Scale(scale, 4) @ Matrix.Translation((-centre.x, -centre.y, 0)))
        # `transform` también escala el radio de cada punto, y el tubo mide «bevel_depth × radio»: todos a 1.
        for spline in curve.splines:
            for point in (spline.bezier_points if spline.type == "BEZIER" else spline.points):
                point.radius = 1.0
        colors = list(obj.get("neon_colors", [spline.material_index for spline in curve.splines]))
        curve.fill_mode = "FULL"
        curve.bevel_depth = TUBE
        # Lo justo para que el tubo se vea redondo y las curvas suaves desde la cámara: más segmentos solo suman triángulos.
        curve.bevel_resolution = 1
        curve.resolution_u = 4
        curve.use_fill_caps = True
        curve.materials.clear()
        for index, color in enumerate(COLORS[name]):
            curve.materials.append(_neon_material(f"{PREFIX}{name}_{index}", color))
        # Cambiar los materiales reinicia el de cada trazo: se vuelve a poner.
        for spline, index in zip(curve.splines, colors):
            spline.material_index = min(index, len(COLORS[name]) - 1)
        made.append(obj)
    # Curva → malla, para que se exporte y se hornee como el resto.
    for obj in made:
        bpy.ops.object.select_all(action="DESELECT")
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        bpy.ops.object.convert(target="MESH")
        obj.data.uv_layers.new(name="UVMap")
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    # Los emisores de luz: una copia de cada tubo, invisible a cámara, en la colección de la luz del horneado (no se exporta).
    lighting = bpy.data.collections["BAKE_lighting"]
    for obj in made:
        name = obj.name[len(PREFIX):]
        glow = bpy.data.objects.new(f"{GLOW_PREFIX}{name}", obj.data.copy())
        glow.matrix_world = obj.matrix_world.copy()
        glow.data.materials.clear()
        for index, color in enumerate(COLORS[name]):
            glow.data.materials.append(_glow_material(f"{GLOW_PREFIX}{name}_{index}", color))
        glow.visible_camera = False
        lighting.objects.link(glow)
    for collection_ in [c for c in bpy.data.collections if c.name.endswith(".svg") and not c.objects]:
        bpy.data.collections.remove(collection_)
    source.hide_set(True)
    source.hide_render = True
    print("Neones", [o.name for o in made])
    return made
