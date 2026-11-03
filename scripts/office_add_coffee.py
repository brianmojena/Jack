"""Alarga la pared del espejo y el suelo hacia delante (como la de la tele) y pone una cafetera con su vapor animado sobre una
mesita low poly, en la esquina que queda libre.

Uso (el .blend se guarda al terminar):

    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_coffee.py -- \\
        "~/Downloads/cafetera-profesional-mtrl/source/CAFETERA PROFESIONAL MTRL.glb"

El GLB no se guarda en el repositorio: la cafetera queda dentro de Office.blend.

Lo que hace:
 - alarga hacia delante (-y) la pared del espejo, su zócalo, el suelo y el techo. Para no estirar la textura, corta cada
   malla cerca del borde y estira solo esa franja, con la UV continuada (el suelo) o en espejo (la pared, que no se repite);
 - mueve con el borde el sofá grande, para que siga pegado a él, y con él las posturas de quienes se sientan ahí en
   Runtime/OfficeLayout.json (y el límite de la sala);
 - añade la mesita (`PROP_coffee_table`, con los materiales de la mesa de ajedrez) y encima la cafetera, sin la mesa que trae
   el GLB y con menos polígonos, bajo el vacío `COFFEE`. Su vapor sube de las tazas con una animación propia, así que la
   cafetera no viaja con la sala: `office_export_blender.py` la exporta aparte (OfficeCoffee.usdz) y la app la coloca en
   el marcador `PROP_coffee_spot`.
Se puede volver a ejecutar: la sala solo se alarga una vez y la cafetera anterior se sustituye.
"""
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAYOUT = os.path.join(ROOT, "Resources", "Office", "Runtime", "OfficeLayout.json")
FRONT = -15.47        # donde terminaba la sala por delante
NEW_FRONT = -18.0     # donde termina ahora (lo mismo que se alargó la pared de la tele)
CUT = -15.0           # se estira solo la franja entre el corte y el borde
FLOOR = "Object_194"
WALL = "Object_196"
BASEBOARD = "Object_202"
CEILING = "Object_200"
SOFA = "PROP_sofa_big"

SCALE = 3.2           # de la cafetera del GLB (1 m de ancho) a la sala
GLB_COUNTER = 0.705   # la altura del mostrador sobre el que está en el GLB
TABLE_TOP = 2.48      # la misma altura que los escritorios
TABLE_THICKNESS = 0.18
TABLE_X = (-5.75, -2.85)   # contra la pared del espejo (su zócalo está en -5.87)
TABLE_Y = (-17.4, -12.6)
LEG = 0.24
COFFEE_X = -3.95      # origen de la cafetera: deja su parte trasera junto a la pared
DROP = ("table", "table.001", "cups_under_table")  # la mesa del GLB y lo que hay debajo
STEAM = "dimok"       # el material del vapor
# Polígonos que se quieren de cada pieza (el GLB tiene más de 600 000).
TARGET = {"coffemashine_Rancilio_xcelsius_x3": 15000, "coffemashine_Rancilio_xcelsius_x3.001": 4000}
DEFAULT_RATIO = 0.15
STEAM_RATIO = 0.3


# MARK: - Sala

def _affine(face, world, uv):
    """La UV de una cara como función de un punto de su plano (sirve fuera de la cara: la extrapola)."""
    loops = list(face.loops)
    p0 = world @ loops[0].vert.co
    u0 = loops[0][uv].uv.copy()
    for i in range(1, len(loops) - 1):
        e1 = world @ loops[i].vert.co - p0
        e2 = world @ loops[i + 1].vert.co - p0
        if e1.cross(e2).length > 1e-8:
            d1 = loops[i][uv].uv - u0
            d2 = loops[i + 1][uv].uv - u0
            break
    else:
        return None
    a, b, c = e1.dot(e1), e1.dot(e2), e2.dot(e2)
    det = a * c - b * b

    def at(point):
        d = point - p0
        s = (c * d.dot(e1) - b * d.dot(e2)) / det
        t = (a * d.dot(e2) - b * d.dot(e1)) / det
        return u0 + d1 * s + d2 * t
    return at


def extend_front(name, mirror):
    """Corta la malla en CUT y lleva hasta NEW_FRONT lo que queda por delante. La UV de lo estirado se calcula con la de su
    cara: seguida (`mirror=False`) o reflejada en el corte, para las texturas que no se repiten bien."""
    obj = bpy.data.objects[name]
    world = obj.matrix_world
    local = world.inverted()
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    uv = mesh.loops.layers.uv.active
    bmesh.ops.bisect_plane(mesh, geom=mesh.verts[:] + mesh.edges[:] + mesh.faces[:],
                           plane_co=local @ Vector((0, CUT, 0)), plane_no=Vector((0, 1, 0)))
    moved = {v for v in mesh.verts if (world @ v.co).y < CUT - 1e-4}
    maps = {}
    if uv is not None:
        for face in {f for v in moved for f in v.link_faces}:
            if abs((world.to_3x3() @ face.normal).normalized().y) < 0.9:
                maps[face] = _affine(face, world, uv)
    stretch = (CUT - NEW_FRONT) / (CUT - FRONT)
    for vert in moved:
        point = world @ vert.co
        point.y = CUT - (CUT - point.y) * stretch
        vert.co = local @ point
    for face, at in maps.items():
        if at is None:
            continue
        for loop in face.loops:
            if loop.vert in moved:
                point = world @ loop.vert.co
                if mirror:
                    point.y = 2 * CUT - point.y
                loop[uv].uv = at(point)
    mesh.to_mesh(obj.data)
    mesh.free()
    obj.data.update()


def shift_front(name):
    """Lleva hasta NEW_FRONT los vértices del borde (el techo no tiene textura que cuidar)."""
    obj = bpy.data.objects[name]
    world = obj.matrix_world
    local = world.inverted()
    for vert in obj.data.vertices:
        point = world @ vert.co
        if point.y < FRONT + 0.2:
            point.y += NEW_FRONT - FRONT
            vert.co = local @ point
    obj.data.update()


def bounds(obj):
    points = [o.matrix_world @ Vector(c) for o in [obj] + list(obj.children_recursive) if o.type == "MESH" for c in o.bound_box]
    return (Vector([min(p[i] for p in points) for i in range(3)]), Vector([max(p[i] for p in points) for i in range(3)]))


def shift_sofa_seats(low, high, delta):
    """Las posturas de quienes se sientan en el sofá que se mueve: el sofá, levantarse y sentarse se desplazan enteros; el
    tramo de caminar de Blender, poco a poco (la app calcula el suyo, pero así queda bien si no puede)."""
    with open(LAYOUT) as file:
        layout = json.load(file)
    for slot in layout["slots"]:
        x, y = slot["sofa"][0], slot["sofa"][1]
        if not (low.x <= x <= high.x and low.y <= y <= high.y):
            continue
        slot["sofa"][1] = round(slot["sofa"][1] + delta, 5)
        slot["atSofa"][1] = round(slot["atSofa"][1] + delta, 5)
        go, back = slot["toDesk"], slot["toSofa"]
        walk = next(c for c in go["clips"] if c["clip"] == "walk")
        for index, frame in enumerate(go["root"]):
            if index < walk["from"]:
                frame[1] = round(frame[1] + delta, 5)
            elif index < walk["to"]:
                frame[1] = round(frame[1] + delta * (1 - (index - walk["from"]) / (walk["to"] - walk["from"])), 5)
        walk = next(c for c in back["clips"] if c["clip"] == "walk")
        for index, frame in enumerate(back["root"]):
            if index >= walk["to"]:
                frame[1] = round(frame[1] + delta, 5)
            elif index >= walk["from"]:
                frame[1] = round(frame[1] + delta * (index - walk["from"]) / (walk["to"] - walk["from"]), 5)
        print("Sofá movido para", slot["id"])
    layout["room"]["min"][1] = NEW_FRONT
    with open(LAYOUT, "w") as file:
        file.write(json.dumps(layout, separators=(",", ":"), ensure_ascii=False))


def extend_room():
    floor = bpy.data.objects[FLOOR]
    if min((floor.matrix_world @ v.co).y for v in floor.data.vertices) < FRONT - 0.1:
        print("La sala ya estaba alargada por delante")
        return
    extend_front(FLOOR, mirror=False)
    extend_front(WALL, mirror=True)
    extend_front(BASEBOARD, mirror=True)
    shift_front(CEILING)
    sofa = bpy.data.objects[SOFA]
    low, high = bounds(sofa)
    sofa.location.y += NEW_FRONT - FRONT
    shift_sofa_seats(low, high, NEW_FRONT - FRONT)


# MARK: - Mesita y cafetera

def box(name, low, high, material):
    mesh = bpy.data.meshes.new(name)
    corners = [(x, y, z) for z in (low.z, high.z) for y in (low.y, high.y) for x in (low.x, high.x)]
    faces = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
    mesh.from_pydata(corners, [], faces)
    mesh.materials.append(bpy.data.materials.get(material))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def add_table():
    top = box("PROP_coffee_table", Vector((TABLE_X[0], TABLE_Y[0], TABLE_TOP - TABLE_THICKNESS)), Vector((TABLE_X[1], TABLE_Y[1], TABLE_TOP)),
              "CHESS_table_wood")
    inset = 0.18
    for name, x, y in (("sw", TABLE_X[0] + inset, TABLE_Y[0] + inset), ("se", TABLE_X[1] - inset - LEG, TABLE_Y[0] + inset),
                       ("nw", TABLE_X[0] + inset, TABLE_Y[1] - inset - LEG), ("ne", TABLE_X[1] - inset - LEG, TABLE_Y[1] - inset - LEG)):
        leg = box(f"PROP_coffee_table_leg_{name}", Vector((x, y, 0)), Vector((x + LEG, y + LEG, TABLE_TOP - TABLE_THICKNESS)), "CHESS_table_steel")
        leg.parent = top


def decimate(obj, ratio):
    if ratio >= 1 or len(obj.data.polygons) < 300:
        return
    modifier = obj.modifiers.new("decimate", "DECIMATE")
    modifier.ratio = ratio
    depsgraph = bpy.context.evaluated_depsgraph_get()
    reduced = bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph))
    obj.modifiers.remove(modifier)
    old = obj.data
    obj.data = reduced
    if old.users == 0:
        bpy.data.meshes.remove(old)


def add_coffee(path):
    before = set(bpy.data.objects)
    images, materials = set(bpy.data.images), set(bpy.data.materials)
    bpy.ops.import_scene.gltf(filepath=path)
    imported = [o for o in bpy.data.objects if o not in before]
    for name in DROP:
        found = next((o for o in imported if o.name == name), None)
        if found:
            for obj in [found] + list(found.children_recursive):
                imported.remove(obj)
                bpy.data.objects.remove(obj, do_unlink=True)
    for image in [i for i in bpy.data.images if i not in images]:
        image.name = "coffee_" + image.name.replace(".", "_")
    for material in [m for m in bpy.data.materials if m not in materials]:
        material.name = "coffee_" + material.name.replace(".", "_")

    steam = 0
    for obj in imported:
        if obj.type == "MESH":
            is_steam = any(m and m.name == f"coffee_{STEAM}" for m in obj.data.materials)
            decimate(obj, STEAM_RATIO if is_steam else TARGET.get(obj.name, 0) / len(obj.data.polygons) if obj.name in TARGET else DEFAULT_RATIO)
            if is_steam:
                steam += 1
                obj.name = f"COFFEE_steam_{steam}"
                continue
        obj.name = "COFFEE_" + obj.name.replace(".", "_")

    # Todo bajo un vacío: girado para que la cafetera mire a la sala (su frente es -y), a escala y con el mostrador del GLB a
    # la altura de la mesita.
    root = bpy.data.objects.new("COFFEE", None)
    bpy.context.scene.collection.objects.link(root)
    center_y = (TABLE_Y[0] + TABLE_Y[1]) / 2
    root.location = (COFFEE_X, center_y, TABLE_TOP - GLB_COUNTER * SCALE)
    root.rotation_euler = (0, 0, math.radians(90))
    root.scale = (SCALE,) * 3
    for obj in imported:
        if obj.parent is None:
            obj.parent = root
    bpy.context.view_layer.update()
    # Centrada a lo largo de la mesita (las tazas de al lado hacen que el GLB no esté centrado en su origen).
    low, high = bounds(root)
    root.location.y += center_y - (low.y + high.y) / 2
    bpy.context.view_layer.update()
    marker = bpy.data.objects.new("PROP_coffee_spot", None)
    bpy.context.scene.collection.objects.link(marker)
    marker.location = root.location
    low, high = bounds(root)
    print(f"Cafetera: x {low.x:.2f}…{high.x:.2f}, y {low.y:.2f}…{high.y:.2f}, z {low.z:.2f}…{high.z:.2f}; "
          f"{sum(len(o.data.polygons) for o in root.children_recursive if o.type == 'MESH')} polígonos, {steam} vapores")


def clean():
    for obj in list(bpy.data.objects):
        if obj.name.startswith(("COFFEE", "PROP_coffee")):
            bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in [m for m in bpy.data.meshes if m.users == 0]:
        bpy.data.meshes.remove(mesh)
    for material in [m for m in bpy.data.materials if m.name.startswith("coffee_") and m.users == 0]:
        bpy.data.materials.remove(material)
    for image in [i for i in bpy.data.images if i.name.startswith("coffee_") and i.users == 0]:
        bpy.data.images.remove(image)
    for action in [a for a in bpy.data.actions if a.users == 0]:
        bpy.data.actions.remove(action)


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if len(args) != 1:
        raise SystemExit("Uso: … --python scripts/office_add_coffee.py -- cafetera.glb")
    extend_room()
    clean()
    add_table()
    add_coffee(os.path.expanduser(args[0]))
    bpy.ops.wm.save_mainfile()
    print("Guardado", bpy.data.filepath)


main()
