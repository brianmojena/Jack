"""Añade a Office.blend la mesa de ajedrez (mesa, tablero y 32 piezas sueltas) y escribe Runtime/OfficeChess.json.

Uso (el .blend se guarda al terminar):

    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_chess.py -- \\
        ~/Downloads/low_poly_chess_-_chess_board.glb

El GLB (un tablero low poly con sus piezas) no se guarda en el repositorio: las piezas quedan dentro de Office.blend.

Lo que hace:
 - importa el GLB, quita sus luces y vacíos, y deja cada pieza como un objeto suelto `CHESS_<color><pieza>_<casilla inicial>`
   (por ejemplo `CHESS_wP_e2`) con el origen en el centro de su base, para poder moverlas por el tablero desde la app;
 - escala y gira el juego (las blancas miran al oeste) y lo apoya en una mesa nueva, a la altura de los escritorios;
 - escribe el JSON con las casillas, las piezas, los dos asientos y las filas donde van las piezas comidas.
Después, `scripts/office-assets.sh` exporta la sala (la mesa y las piezas viajan en OfficeRoom.usdz).
"""
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Centro de la mesa en la sala (coordenadas de Blender): el hueco libre a la derecha de la alfombra.
CENTER = Vector((7.2, -6.2))
TABLE_TOP = 2.48      # la misma altura que los escritorios
TABLE_SIZE = 4.4      # lado de la mesa
TABLE_THICKNESS = 0.18
SCALE = 0.30          # del GLB (casillas de 1.2) a la sala: casillas de 0.36
SEAT_GAP = 0.90       # de la cadera sentada al canto de la mesa (como en los escritorios)
KINDS = {"Pawn": "P", "Knight": "N", "Bishop": "B", "Rook": "R", "Queen": "Q", "King": "K"}
KIND_NAMES = {"P": "pawn", "N": "knight", "B": "bishop", "R": "rook", "Q": "queen", "K": "king"}


def square_name(file, rank):
    return "abcdefgh"[file] + str(rank + 1)


def clean():
    for obj in list(bpy.data.objects):
        if obj.name.startswith("CHESS_"):
            bpy.data.objects.remove(obj, do_unlink=True)


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def flatten(obj):
    """Hornea la transformación del objeto (y de sus padres) en la malla y lo deja sin padre."""
    matrix = obj.matrix_world.copy()
    obj.parent = None
    obj.data.transform(matrix)
    obj.matrix_world = Matrix.Identity(4)


def base_center(obj):
    # De los vértices (la caja del objeto puede no estar al día tras transformar la malla).
    points = [obj.matrix_world @ vertex.co for vertex in obj.data.vertices]
    xs, ys, zs = [p.x for p in points], [p.y for p in points], [p.z for p in points]
    return Vector(((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, min(zs)))


def place(obj, origin, transform):
    """El origen del objeto en `origin` (local del tablero) y la malla relativa a él, ya escalada y girada."""
    obj.data.transform(Matrix.Translation(-origin))
    obj.data.transform(transform.to_3x3().to_4x4())
    obj.location = transform @ origin
    obj.rotation_euler = (0, 0, 0)
    obj.scale = (1, 1, 1)


def box(name, size, location, material):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    return obj


def cylinder(name, radius, depth, location, material):
    bpy.ops.mesh.primitive_cylinder_add(radius=radius, depth=depth, location=location, vertices=24)
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def material(name, color, roughness, metallic=0.0):
    found = bpy.data.materials.get(name)
    if found:
        bpy.data.materials.remove(found)
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    shader = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    shader.inputs["Base Color"].default_value = (*color, 1)
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    return mat


def principled(mat):
    return next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")


def main():
    args = sys.argv[sys.argv.index("--") + 1:]
    glb = os.path.expanduser(args[0])
    clean()
    imported = import_glb(glb)
    bpy.context.view_layer.update()
    # Primero se hornea cada malla (necesita a sus padres) y después se quitan los vacíos, luces y cámaras del GLB.
    meshes = [o for o in imported if o.type == "MESH"]
    for obj in meshes:
        flatten(obj)
    for obj in imported:
        if obj.type != "MESH":
            bpy.data.objects.remove(obj, do_unlink=True)

    # El tablero va con su centro en el origen y la cara superior de las casillas en z = 0 (las piezas se apoyan ahí).
    transform = Matrix.Translation((CENTER.x, CENTER.y, TABLE_TOP + 0.24 * SCALE)) @ Matrix.Rotation(math.radians(-90), 4, "Z") @ Matrix.Scale(SCALE, 4)
    pieces = []
    for obj in meshes:
        stem = obj.name.split("_")
        if obj.name.startswith(("Board_Frame_0")):
            place(obj, Vector((0, 0, 0)), transform)
            obj.name = "CHESS_board_frame"
        elif obj.name.startswith("Board_Frame_1"):
            place(obj, Vector((0, 0, 0)), transform)
            obj.name = "CHESS_board_light"
        elif obj.name.startswith("Board_Frame_2"):
            place(obj, Vector((0, 0, 0)), transform)
            obj.name = "CHESS_board_dark"
        else:
            color = "w" if obj.name.startswith("White") else "b"
            kind = next(letter for word, letter in KINDS.items() if word in obj.name)
            origin = base_center(obj)
            # Casilla de salida: el GLB pone las columnas de -4.2 a 4.2 (de la a a la h) y las filas igual.
            file, rank = round((origin.x + 4.2) / 1.2), round((origin.y + 4.2) / 1.2)
            name = f"CHESS_{color}{kind}_{square_name(file, rank)}"
            place(obj, origin, transform)
            obj.name = name
            obj.data.name = name
            pieces.append({"name": name, "color": "white" if color == "w" else "black", "kind": KIND_NAMES[kind], "square": square_name(file, rank)})
    assert len(pieces) == 32, f"se esperaban 32 piezas y hay {len(pieces)}"

    # Que el tablero no deslumbre en la sala oscura, y las casillas negras no sean un negro plano.
    for obj in bpy.data.objects:
        if not obj.name.startswith("CHESS_"):
            continue
        for slot in obj.material_slots:
            mat = slot.material
            if mat is None or principled(mat) is None:
                continue
            shader = principled(mat)
            if mat.name.startswith("White_Square"):
                shader.inputs["Base Color"].default_value = (0.80, 0.74, 0.62, 1)
            elif mat.name.startswith("Black_Square"):
                shader.inputs["Base Color"].default_value = (0.045, 0.035, 0.03, 1)

    # La mesa: tablero de nogal oscuro sobre cuatro patas negras.
    wood = material("CHESS_table_wood", (0.20, 0.10, 0.05), 0.45)
    steel = material("CHESS_table_steel", (0.03, 0.03, 0.035), 0.35, 0.85)
    box("CHESS_table_top", (TABLE_SIZE, TABLE_SIZE, TABLE_THICKNESS), (CENTER.x, CENTER.y, TABLE_TOP - TABLE_THICKNESS / 2), wood)
    inset = TABLE_SIZE / 2 - 0.32
    leg_height = TABLE_TOP - TABLE_THICKNESS
    for sx in (-1, 1):
        for sy in (-1, 1):
            cylinder(f"CHESS_table_leg_{'e' if sx > 0 else 'w'}{'n' if sy > 0 else 's'}", 0.13, leg_height,
                     (CENTER.x + sx * inset, CENTER.y + sy * inset, leg_height / 2), steel)

    # Casillas (centro de cada una, a la altura de la base de las piezas), en coordenadas de Blender.
    squares = []
    for rank in range(8):
        for file in range(8):
            local = Vector((-4.2 + 1.2 * file, -4.2 + 1.2 * rank, 0))
            point = transform @ local
            squares.append([round(point.x, 4), round(point.y, 4), round(point.z, 4)])
    half = TABLE_SIZE / 2
    layout = {
        "units": "coordenadas de Blender (x, y, z arriba), como OfficeLayout.json",
        "square": round(1.2 * SCALE, 4),
        "squares": squares,
        "pieces": sorted(pieces, key=lambda p: p["name"]),
        "table": {"center": [CENTER.x, CENTER.y], "half": half, "top": TABLE_TOP},
        # Dónde se sienta cada bando: cadera final y hacia dónde mira. Las blancas, al oeste.
        "seats": [
            {"color": "white", "position": [CENTER.x - half - SEAT_GAP, CENTER.y], "yaw": 90.0},
            {"color": "black", "position": [CENTER.x + half + SEAT_GAP, CENTER.y], "yaw": 270.0},
        ],
        # Filas de piezas comidas, en los cantos norte y sur de la mesa: de cada color, en el canto que le queda a su lado.
        "graveyards": {
            "white": {"start": [CENTER.x - 1.5, CENTER.y + half - 0.3, TABLE_TOP], "step": [0.2, 0.0]},
            "black": {"start": [CENTER.x - 1.5, CENTER.y - half + 0.3, TABLE_TOP], "step": [0.2, 0.0]},
        },
    }
    path = os.path.join(ROOT, "Resources", "Office", "Runtime", "OfficeChess.json")
    with open(path, "w") as handle:
        json.dump(layout, handle, indent=1)
    bpy.ops.wm.save_mainfile()
    print(f"Mesa de ajedrez lista: {len(pieces)} piezas, JSON en {path}")


main()
