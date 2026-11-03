"""Alarga la pared de la tele y el suelo de Office.blend, y pone en ese hueco una ducha low poly.

Uso (el .blend se guarda al terminar):

    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_shower.py -- \\
        ~/Downloads/ducha_low.glb

El GLB no se guarda en el repositorio: la ducha queda dentro de Office.blend.

Lo que hace:
 - alarga hacia la derecha (+x) la pared del fondo, la de la tele, con la textura continuada en espejo para que no se
   note la junta; el suelo, con sus tablas siguiendo; el techo, y el canto de la pared (ROOM_merged_0);
 - importa la ducha como `PROP_shower` (un vacío con la ducha y su cristal fijo), con el fondo contra la pared, el panel
   de los grifos junto al escritorio 3 y la mampara dando a la sala;
 - deja la puerta de la mampara como `PROP_shower_door`, cerrada y con el origen en la bisagra (la app la abre), y tres
   marcadores: `PROP_shower_inside` (dónde se ducha), `PROP_shower_wait` (dónde espera a que se abra) y
   `PROP_shower_head` (de dónde cae el agua).
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
SHOWER_LEFT = 11.0    # canto izquierdo de la ducha: deja paso junto al escritorio 3
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


def loose_parts(obj):
    """Las piezas sueltas de una malla, como conjuntos de índices de vértices."""
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    mesh.verts.ensure_lookup_table()
    seen, parts = set(), []
    for vert in mesh.verts:
        if vert.index in seen:
            continue
        stack, part = [vert], set()
        seen.add(vert.index)
        while stack:
            current = stack.pop()
            part.add(current.index)
            for edge in current.link_edges:
                other = edge.other_vert(current)
                if other.index not in seen:
                    seen.add(other.index)
                    stack.append(other)
        parts.append(part)
    mesh.free()
    return parts


def split(obj, indices, name):
    """Saca de `obj` los vértices `indices` (con sus caras) a un objeto nuevo `name`."""
    copy = obj.copy()
    copy.data = obj.data.copy()
    copy.name = copy.data.name = name
    bpy.context.scene.collection.objects.link(copy)
    for target, keep in ((obj, lambda i: i not in indices), (copy, lambda i: i in indices)):
        mesh = bmesh.new()
        mesh.from_mesh(target.data)
        mesh.verts.ensure_lookup_table()
        bmesh.ops.delete(mesh, geom=[v for v in mesh.verts if not keep(v.index)], context="VERTS")
        mesh.to_mesh(target.data)
        mesh.free()
    return copy


def marker(name, location):
    empty = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(empty)
    empty.location = location
    return empty


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
    body = next(o for o in meshes if "ducha" in o.name)
    glass = next(o for o in meshes if "cristal" in o.name)
    body.name, glass.name = "PROP_shower_body", "PROP_shower_glass"

    # Sin girar: la mampara da a la sala, el panel de los grifos queda junto al escritorio 3 y el fondo, contra la pared.
    for obj in meshes:
        obj.data.transform(Matrix.Scale(SCALE, 4))
    low_z = min(v.co.z for o in meshes for v in o.data.vertices)
    offset = Vector((SHOWER_LEFT - min(v.co.x for v in body.data.vertices),
                     WALL_Y - WALL_GAP - max(v.co.y for v in body.data.vertices), -low_z))
    for obj in meshes:
        obj.data.transform(Matrix.Translation(offset))  # desde aquí, coordenadas de la sala
    body_points = [v.co.copy() for v in body.data.vertices]
    tray_front = min(p.y for p in body_points)

    # La puerta de la mampara: el cristal que sobresale por delante del plato (viene abierta). Pasa a ser un objeto suelto,
    # cerrada y con el origen en la bisagra, para que la app la abra girándola sobre su eje vertical.
    door_parts = [part for part in loose_parts(glass) if min(glass.data.vertices[i].co.y for i in part) < tray_front - 0.3]
    door_indices = set().union(*door_parts)
    door = split(glass, door_indices, "PROP_shower_door")
    points = [v.co.copy() for v in door.data.vertices]
    top, bottom = max(p.y for p in points), min(p.y for p in points)
    near = [p for p in points if p.y > top - 0.5]
    far = [p for p in points if p.y < bottom + 0.5]
    hinge = sum(near, Vector()) / len(near)
    tip = sum(far, Vector()) / len(far)
    hinge.z = 0
    angle = math.atan2(tip.y - hinge.y, tip.x - hinge.x)
    door.data.transform(Matrix.Rotation(-angle, 4, "Z") @ Matrix.Translation(-hinge))
    door.location = hinge
    length = (tip.xy - hinge.xy).length

    root = bpy.data.objects.new("PROP_shower", None)
    bpy.context.scene.collection.objects.link(root)
    root.location = offset
    for obj in (body, glass):
        obj.data.transform(Matrix.Translation(-offset))
        obj.parent = root

    # Dónde se pone dentro (el centro del plato, encima de él), dónde espera fuera mientras se abre la puerta y de dónde cae
    # el agua (la alcachofa: la pieza más ancha colgada dentro del plato).
    parts = [[body_points[i] for i in part] for part in loose_parts(body)]
    tray = max((p for p in parts if max(q.z for q in p) < 0.5),
               key=lambda p: (max(q.x for q in p) - min(q.x for q in p)) * (max(q.y for q in p) - min(q.y for q in p)))
    tray_low = Vector((min(q.x for q in tray), min(q.y for q in tray)))
    tray_high = Vector((max(q.x for q in tray), max(q.y for q in tray)))
    center = (tray_low + tray_high) / 2
    inner = (tray_high - tray_low) * 0.35
    hanging = [p for p in parts if all(abs(q.x - center.x) < inner.x and abs(q.y - center.y) < inner.y for q in p)
               and min(q.z for q in p) > 4.0]
    head = max(hanging, key=lambda p: (max(q.x for q in p) - min(q.x for q in p)) * (max(q.y for q in p) - min(q.y for q in p)))
    head_center = sum(head, Vector()) / len(head)
    marker("PROP_shower_inside", (center.x, center.y, max(q.z for q in tray)))
    marker("PROP_shower_wait", (center.x + 0.3, hinge.y - length - 0.7, 0))
    marker("PROP_shower_head", (head_center.x, head_center.y, min(q.z for q in head)))
    bpy.context.view_layer.update()
    print(f"Ducha: plato x {tray_low.x:.2f}…{tray_high.x:.2f}, y {tray_low.y:.2f}…{tray_high.y:.2f}; bisagra {hinge.x:.2f}, "
          f"{hinge.y:.2f}; puerta {length:.2f} (abierta {math.degrees(angle):.0f}°); alcachofa {head_center.x:.2f}, "
          f"{head_center.y:.2f}, {min(q.z for q in head):.2f} ({len(hanging)} piezas colgadas)")


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if len(args) != 1:
        raise SystemExit("Uso: … --python scripts/office_add_shower.py -- ducha.glb")
    extend_room()
    add_shower(args[0])
    bpy.ops.wm.save_mainfile()
    print("Guardado", bpy.data.filepath)


main()
