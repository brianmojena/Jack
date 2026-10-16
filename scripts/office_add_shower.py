"""Alarga la pared de la tele y el suelo de Office.blend, y pone en ese hueco una ducha low poly.

Uso (el .blend se guarda al terminar):

    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_shower.py -- \\
        ~/Downloads/ducha_low.glb

El GLB no se guarda en el repositorio: la ducha queda dentro de Office.blend.

Lo que hace:
 - alarga hacia la derecha (+x) la pared del fondo, la de la tele, con la textura continuada en espejo para que no se
   note la junta; el suelo, con sus tablas siguiendo; el techo, y el canto de la pared (ROOM_merged_0);
 - importa la ducha como `PROP_shower` (un vacío con la ducha y su cristal), con la columna de grifos contra la pared y
   la mampara abierta a lo largo de ella, detrás del escritorio 3.
Se puede volver a ejecutar: la sala solo se alarga una vez y la ducha anterior se sustituye.
Después, `scripts/office-assets.sh` exporta la sala (la ducha viaja en OfficeRoom.usdz).
"""
import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOM_END = 12.47      # donde terminaba la sala por la derecha
NEW_END = 15.0        # donde termina ahora
WALL_Y = 7.06         # la pared del fondo, la de la tele
FLOOR = "Object_194"
WALL = "Object_388"
CEILING = "Object_200"
WALL_EDGE = "ROOM_merged_0"
SCALE = 3.0           # del GLB (plato de 1,1) a la sala: plato de 3,3, para personajes de unos 6 de alto
SHOWER_RIGHT = 14.3   # canto derecho del plato
WALL_GAP = 0.02


def _edge_verts(obj, mesh, x):
    world = obj.matrix_world
    return [v for v in mesh.verts if abs((world @ v.co).x - x) < 0.02]


def extend_plane(name, mirror_u):
    """Añade a un plano (suelo o pared) una franja de ROOM_END a NEW_END, pegada a su canto derecho.

    La UV sigue la misma escala que la cara vecina; con `mirror_u` vuelve hacia atrás (textura en espejo), para las
    texturas que no se repiten bien.
    """
    obj = bpy.data.objects[name]
    world = obj.matrix_world
    local = world.inverted()
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    uv = mesh.loops.layers.uv.active
    edge = _edge_verts(obj, mesh, ROOM_END)
    assert len(edge) == 2, f"{name}: se esperaban 2 vértices en el canto, hay {len(edge)}"
    # La cara que contiene el canto da la UV de cada vértice y cuánto cambia la U por unidad de x.
    face = next(f for f in mesh.faces if all(v in f.verts for v in edge))
    loops = {loop.vert: loop[uv].uv.copy() for loop in face.loops}
    other = next(v for v in face.verts if v not in edge)
    du = (loops[edge[0]].x - loops[other].x) / ((world @ edge[0].co).x - (world @ other.co).x)
    step = (NEW_END - ROOM_END) * (-du if mirror_u else du)
    added = []
    for vert in edge:
        point = world @ vert.co
        added.append(mesh.verts.new(local @ Vector((NEW_END, point.y, point.z))))
    new = mesh.faces.new((edge[0], added[0], added[1], edge[1]))
    mesh.normal_update()
    if new.normal.dot(face.normal) < 0:
        new.normal_flip()
    new.material_index = face.material_index
    for loop in new.loops:
        if loop.vert in loops:
            loop[uv].uv = loops[loop.vert]
        else:
            source = edge[added.index(loop.vert)]
            loop[uv].uv = (loops[source].x + step, loops[source].y)
    mesh.to_mesh(obj.data)
    mesh.free()
    obj.data.update()


def stretch(name):
    """Lleva hasta NEW_END los vértices del canto derecho (el techo y el canto de la pared no tienen textura que cuidar)."""
    obj = bpy.data.objects[name]
    world = obj.matrix_world
    local = world.inverted()
    for vert in obj.data.vertices:
        point = world @ vert.co
        if point.x > ROOM_END - 0.1:
            point.x += NEW_END - ROOM_END
            vert.co = local @ point
    obj.data.update()


def extend_room():
    floor = bpy.data.objects[FLOOR]
    if max((floor.matrix_world @ v.co).x for v in floor.data.vertices) > ROOM_END + 0.1:
        print("La sala ya estaba alargada")
        return
    extend_plane(FLOOR, mirror_u=False)
    extend_plane(WALL, mirror_u=True)
    stretch(CEILING)
    stretch(WALL_EDGE)


def flatten(obj):
    matrix = obj.matrix_world.copy()
    obj.parent = None
    obj.data.transform(matrix)
    obj.matrix_world = Matrix.Identity(4)


def add_shower(path):
    for obj in list(bpy.data.objects):
        if obj.name.startswith("PROP_shower"):
            bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in [m for m in bpy.data.meshes if m.users == 0]:
        bpy.data.meshes.remove(mesh)
    for material in [m for m in bpy.data.materials if m.name.startswith("shower_") and m.users == 0]:
        bpy.data.materials.remove(material)
    for image in [i for i in bpy.data.images if i.name.startswith("shower_") and i.users == 0]:
        bpy.data.images.remove(image)
    before = set(bpy.data.objects)
    images = set(bpy.data.images)
    bpy.ops.import_scene.gltf(filepath=path)
    imported = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in imported if o.type == "MESH"]
    for obj in meshes:
        flatten(obj)
    for obj in imported:
        if obj.type != "MESH":
            bpy.data.objects.remove(obj, do_unlink=True)
    for index, image in enumerate([i for i in bpy.data.images if i not in images]):
        image.name = f"shower_{index}"
    for material in {m for o in meshes for m in o.data.materials if m}:
        material.name = f"shower_{material.name}"

    # Columna de grifos (lado -x del GLB) contra la pared: giro de -90° sobre el eje vertical.
    turn = Matrix.Rotation(math.radians(-90), 4, "Z") @ Matrix.Scale(SCALE, 4)
    for obj in meshes:
        obj.data.transform(turn)
    points = [v.co for o in meshes for v in o.data.vertices]
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    body = next(o for o in meshes if "ducha" in o.name)
    body_right = max(v.co.x for v in body.data.vertices)
    offset = Vector((SHOWER_RIGHT - body_right, WALL_Y - WALL_GAP - high.y, -low.z))

    root = bpy.data.objects.new("PROP_shower", None)
    bpy.context.scene.collection.objects.link(root)
    root.location = offset
    for obj in meshes:
        obj.name = "PROP_shower_glass" if "cristal" in obj.name else "PROP_shower_body"
        obj.parent = root
    bpy.context.view_layer.update()
    size = high - low
    print(f"Ducha en x {low.x + offset.x:.2f}…{high.x + offset.x:.2f}, y {low.y + offset.y:.2f}…{high.y + offset.y:.2f}, "
          f"alto {size.z:.2f}")


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if len(args) != 1:
        raise SystemExit("Uso: … --python scripts/office_add_shower.py -- ducha.glb")
    extend_room()
    add_shower(args[0])
    bpy.ops.wm.save_mainfile()
    print("Guardado", bpy.data.filepath)


main()
