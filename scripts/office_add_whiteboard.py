"""Alarga otra vez hacia delante la pared del espejo (y el suelo y el techo) para que, pasada la mesita de la cafetera, quede
un trozo de pared libre donde colgar una pizarra, y añade a cada personaje los clips de dibujar en ella.

Uso (el .blend se guarda al terminar):

    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_whiteboard.py

    # solo un personaje y sin guardar, con imágenes de prueba en una carpeta (para mirar cómo quedan los clips):
    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_whiteboard.py -- \\
        --only REMY --preview /tmp/draw

La pizarra no está en el .blend: la app la monta (marco, bandeja y la superficie donde se dibuja) con las medidas que este
script deja en `Runtime/OfficeLayout.json`, clave `whiteboard`, junto con el sitio donde se para quien dibuja.

El movimiento de la mano sale de «Writing» de Mixamo (sentado, escribiendo a mano en una mesa), que se lee de ~/Downloads y no se
guarda en el repositorio: la trayectoria de la mano derecha respecto a su hombro (los trazos, las pausas y el retorno de carro al
acabar la línea) se amplía y se traslada a la pizarra (el avance sobre la mesa pasa a ser altura en la pared), y la postura de
los dedos agarrando el rotulador se copia tal cual. El cuerpo no se toma de ahí: sigue de pie, como en `stand_idle`.

Lo que hace:
 - alarga la sala (como `office_add_coffee.py`: corta cada malla cerca del borde y estira solo esa franja, con la UV continuada
   en el suelo y en espejo en la pared) y actualiza el límite de la sala en el JSON;
 - mueve con el borde el sofá grande, para que siga pegado a él, y con él las posturas de quienes se sientan ahí;
 - añade a cada ALL_<clave>, detrás del último clip (`drink`), tres clips de pie ante la pizarra: `draw_in` (levanta el brazo
   derecho y apoya el rotulador), `draw` (garabatea, en bucle) y `draw_out` (lo baja). El brazo se resuelve por cinemática
   inversa hacia puntos de la pared, así que todos los personajes llegan al mismo sitio aunque midan distinto.
Se puede volver a ejecutar: la sala solo se alarga una vez y los clips anteriores se sustituyen.
"""
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

DOWNLOADS = os.path.expanduser("~/Downloads")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAYOUT = os.path.join(ROOT, "Resources", "Office", "Runtime", "OfficeLayout.json")
FRONT = -18.0         # donde termina ahora la sala por delante
NEW_FRONT = -23.5     # donde termina después
CUT = -17.6           # se estira solo la franja entre el corte y el borde
FLOOR = "Object_194"
WALL = "Object_196"
BASEBOARD = "Object_202"
CEILING = "Object_200"
SOFA = "PROP_sofa_big"

WALL_X = -5.87        # la cara de la pared que mira a la sala
BOARD_WIDTH = 4.0
BOARD_HEIGHT = 2.7
BOARD_Z = 4.6         # el centro de la pizarra, a la altura de los hombros de quien dibuja
BOARD_Y = (FRONT + NEW_FRONT) / 2
BOARD_DEPTH = 0.08    # lo que sobresale de la pared
FPS = 30
LAST_OLD_FRAME = 4025  # el final del clip `drink`, lo último que había
START = LAST_OLD_FRAME + 1
HIPS = "mixamorig:Hips"
STAND_FRAME = 590     # un fotograma dentro del clip `stand_idle`
YAW = {"FRANKLIN": 180}
CHARACTERS = ["REMY", "CH31", "GIRL", "DEADPOOL", "LAMINE", "FRANKLIN"]
# Las muñecas, en el espacio de quien dibuja (x: a su izquierda, y: delante, z: altura; el origen son sus pies).
REACH = 1.0           # lo que se separa la muñeca del cuerpo, hacia la pizarra
HAND_CENTER_X = -0.35  # su brazo derecho queda a este lado del cuerpo
FINGERS = 0.4         # de la muñeca a la punta del rotulador: la pared queda a REACH + FINGERS de los pies
# Cuánto se amplía el movimiento de «Writing» (unidades de la sala por metro de Mixamo): una línea de letra de mano mide unos
# 10 cm; en la pizarra son algo más de una unidad. El avance sobre la mesa se amplía menos, para que las líneas no se tuerzan.
SCALE_SIDE, SCALE_UP = 12.0, 8.0
LIFT = 0.1            # lo que se retira la mano de la pared (unidades) al levantar el rotulador
ROW_GAP = 0.3         # una línea queda sobre y la siguiente bajo la altura de la pizarra, esto de cada lado
LINE_FRAMES = 150     # lo que dura una línea de «Writing» (fotogramas 1 a 150; el 151 es igual al 1)
LINES = 2             # cuántas líneas hace el bucle `draw`
RETURN_FROM = 121     # desde aquí la mano vuelve al principio de la línea: ahí se cambia de fila
IN_FRAMES = 24


# MARK: - Sala (misma idea que office_add_coffee.py)

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
    with open(LAYOUT, "w") as file:
        file.write(json.dumps(layout, separators=(",", ":"), ensure_ascii=False))


def move_sofa():
    """El sofá grande, pegado al borde de delante (como estaba antes de alargar la sala)."""
    sofa = bpy.data.objects[SOFA]
    low, high = bounds(sofa)
    if low.y < FRONT - 1:
        print("El sofá ya estaba junto al borde")
        return
    sofa.location.y += NEW_FRONT - FRONT
    shift_sofa_seats(low, high, NEW_FRONT - FRONT)


def extend_room():
    floor = bpy.data.objects[FLOOR]
    if min((floor.matrix_world @ v.co).y for v in floor.data.vertices) < FRONT - 0.1:
        print("La sala ya estaba alargada")
    else:
        extend_front(FLOOR, mirror=False)
        extend_front(WALL, mirror=True)
        extend_front(BASEBOARD, mirror=True)
        shift_front(CEILING)
    move_sofa()


# MARK: - Clips de dibujar

def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def apply(rig, values):
    for name, (quaternion, location) in values.items():
        pb = rig.pose.bones[name]
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = quaternion
        if location is not None:
            pb.location = location


def key(rig, values, frame, previous):
    """Pone un fotograma clave en cada hueso; el signo de cada cuaternión se ajusta al anterior para que no giren de más."""
    for name, (quaternion, location) in values.items():
        pb = rig.pose.bones[name]
        quaternion = quaternion.copy()
        if name in previous:
            quaternion.make_compatible(previous[name])
        previous[name] = quaternion
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = quaternion
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        if location is not None:
            pb.location = location
            pb.keyframe_insert("location", frame=frame)


def trim(action, last):
    """Quita lo que ya se hubiera añadido detrás del último fotograma original (para poder repetir el script)."""
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    points = curve.keyframe_points
                    for index in reversed(range(len(points))):
                        if points[index].co.x > last:
                            points.remove(points[index])
                    curve.update()


def load_writing():
    """La mano derecha de «Writing» en cada fotograma (de 1 a LINE_FRAMES): dónde está respecto a su hombro, en metros, y los
    giros locales de los huesos de la mano y los dedos (cómo agarra el rotulador)."""
    before = set(bpy.data.objects)
    actions_before = set(bpy.data.actions)
    bpy.ops.import_scene.fbx(filepath=os.path.join(DOWNLOADS, "Writing.fbx"))
    rig = next(o for o in bpy.data.objects if o not in before and o.type == "ARMATURE")
    scene = bpy.context.scene
    hand = rig.pose.bones["mixamorig:RightHand"]
    shoulder = rig.pose.bones["mixamorig:RightArm"]
    # La mano propiamente dicha no se copia (su giro depende de cómo llegue el antebrazo): solo los dedos.
    fingers = [b.name for b in hand.children_recursive]
    frames = []
    for frame in range(1, LINE_FRAMES + 1):
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        offset = (rig.matrix_world @ hand.head) - (rig.matrix_world @ shoulder.head)
        frames.append((offset.copy(), {name: rig.pose.bones[name].rotation_quaternion.copy() for name in fingers}))
    for obj in [rig] + list(rig.children_recursive):
        bpy.data.objects.remove(obj, do_unlink=True)
    for action in [a for a in bpy.data.actions if a not in actions_before]:
        bpy.data.actions.remove(action)
    return frames


def writing_poses(writing):
    """La mano en cada fotograma del bucle (LINES líneas de letra, volviendo al principio al acabar): la muñeca ante la pizarra
    (con el personaje en el origen y de cara a -y; su izquierda es +x) y los dedos."""
    offsets = [w[0] for w in writing]
    mean = sum(offsets, Vector()) / len(offsets)
    low = min(o.y for o in offsets)
    span = max(max(o.y for o in offsets) - low, 1e-6)
    poses = []
    for index in range(LINES * LINE_FRAMES + 1):
        line, step = divmod(index, LINE_FRAMES)
        offset, fingers = writing[step]
        # Cada línea en su fila; al volver al principio (retorno de carro) se pasa a la siguiente.
        rows = [ROW_GAP if n % 2 == 0 else -ROW_GAP for n in (line, line + 1)]
        blend = smooth((step + 1 - RETURN_FROM) / (LINE_FRAMES - RETURN_FROM)) if step + 1 >= RETURN_FROM else 0.0
        row = rows[0] + (rows[1] - rows[0]) * blend
        lift = (offset.y - low) / span * LIFT
        goal = Vector((HAND_CENTER_X + (offset.x - mean.x) * SCALE_SIDE, -REACH + lift, BOARD_Z + row + (offset.z - mean.z) * SCALE_UP))
        poses.append((goal, fingers))
    return poses


def solve_arm(rig, base, goals, fingers=None):
    """La muñeca derecha sigue `goals` (posiciones en el mundo, con el personaje en el origen) con el brazo resuelto por
    cinemática inversa; devuelve los valores de todos los huesos de cada fotograma (el resto, como en `base`). Con `fingers`
    (un giro local por hueso y fotograma), los dedos de la mano derecha se ponen así."""
    apply(rig, base)
    bpy.context.view_layer.update()
    forearm = rig.pose.bones["mixamorig:RightForeArm"]
    empty = bpy.data.objects.new("IK_target", None)
    bpy.context.scene.collection.objects.link(empty)
    constraint = forearm.constraints.new("IK")
    constraint.target = empty
    constraint.chain_count = 2
    constraint.iterations = 60
    constraint.use_stretch = False
    frames = []
    for number, goal in enumerate(goals):
        empty.location = goal
        bpy.context.view_layer.update()
        values = dict(base)
        for name in ("mixamorig:RightArm", "mixamorig:RightForeArm"):
            pb = rig.pose.bones[name]
            basis = rig.convert_space(pose_bone=pb, matrix=pb.matrix, from_space="POSE", to_space="LOCAL")
            values[name] = (basis.to_quaternion(), None)
        if fingers:
            for name, quaternion in fingers[number].items():
                values[name] = (quaternion, None)
        frames.append(values)
    forearm.constraints.remove(constraint)
    bpy.data.objects.remove(empty, do_unlink=True)
    apply(rig, base)
    return frames


def build(key_name, writing, preview):
    rig = bpy.data.objects[f"CHAR_{key_name}_rig"]
    action = bpy.data.actions[f"ALL_{key_name}"]
    trim(action, LAST_OLD_FRAME)
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    scene = bpy.context.scene
    saved = (rig.location.copy(), rig.rotation_euler.copy())
    # Como al exportar: en el origen y con el giro de fábrica, de cara a -y.
    rig.location = (0, 0, 0)
    rig.rotation_euler = (math.radians(90), 0, math.radians(YAW.get(key_name, 0)))
    scene.frame_set(STAND_FRAME)
    bpy.context.view_layer.update()
    base = {}
    for pb in rig.pose.bones:
        pb.rotation_mode = "QUATERNION"
        base[pb.name] = (pb.rotation_quaternion.copy(), pb.location.copy() if pb.name == HIPS else None)
    rest = (rig.matrix_world @ rig.pose.bones["mixamorig:RightHand"].head).copy()

    # Se resuelve con la animación quitada (para que no pise la postura que se prueba) y después se hornean los fotogramas.
    rig.animation_data.action = None
    poses = writing_poses(writing)
    first, first_fingers = poses[0]
    reach = [rest.lerp(first, smooth(index / (IN_FRAMES - 1))) for index in range(IN_FRAMES)]
    # Los dedos pasan de los de la postura de pie a los de agarrar el rotulador.
    # (Algunos personajes no traen los dedos del esqueleto de Mixamo: sin ellos, la mano queda como está.)
    names = [name for name in first_fingers if name in base]
    resting = {name: base[name][0] for name in names}
    closing = [{name: resting[name].slerp(first_fingers[name], smooth(index / (IN_FRAMES - 1))) for name in names} for index in range(IN_FRAMES)]
    frames_in = solve_arm(rig, base, reach, closing)
    frames_loop = solve_arm(rig, base, [goal for goal, _ in poses], [{name: fingers[name] for name in names} for _, fingers in poses])
    pending = [("draw_in", frames_in, False), ("draw", frames_loop, True), ("draw_out", frames_in[::-1], False)]

    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    clips, previous, cursor = {}, {}, START
    for name, frames, repeats in pending:
        for offset, values in enumerate(frames):
            key(rig, values, cursor + offset, previous)
        clips[name] = {"start": round((cursor - 1) / FPS, 5), "duration": round((len(frames) - 1) / FPS, 5), "loop": repeats}
        cursor += len(frames)
    if preview:
        render_preview(rig, key_name, clips, preview)
    rig.location, rig.rotation_euler = saved
    return clips, cursor - 1


# MARK: - Imágenes de prueba

def render_preview(rig, name, clips, folder):
    """Imágenes del personaje ante la pizarra, en varios momentos de cada clip (solo para revisar)."""
    os.makedirs(folder, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    for obj in bpy.data.objects:
        if obj.type == "MESH" and obj.name.startswith("CHAR_") and not obj.name.startswith(f"CHAR_{name}"):
            obj.hide_render = True
        if obj.name.startswith("CHAR_") and obj.type == "ARMATURE" and obj is not rig:
            for child in obj.children_recursive:
                child.hide_render = True
    ceiling = bpy.data.objects.get(CEILING)
    if ceiling:
        ceiling.hide_render = True
    stand = Vector((WALL_X + BOARD_DEPTH + REACH + FINGERS, BOARD_Y + HAND_CENTER_X, 0))
    # De cara a -x: se gira -90° sobre z respecto a mirar a -y.
    rig.location = stand
    rig.rotation_euler = (math.radians(90), 0, math.radians(-90 + YAW.get(name, 0)))
    board = bpy.data.objects.new("PREVIEW_board", bpy.data.meshes.new("PREVIEW_board"))
    mesh = board.data
    x = WALL_X + BOARD_DEPTH
    mesh.from_pydata([(x, BOARD_Y - BOARD_WIDTH / 2, BOARD_Z - BOARD_HEIGHT / 2), (x, BOARD_Y + BOARD_WIDTH / 2, BOARD_Z - BOARD_HEIGHT / 2),
                      (x, BOARD_Y + BOARD_WIDTH / 2, BOARD_Z + BOARD_HEIGHT / 2), (x, BOARD_Y - BOARD_WIDTH / 2, BOARD_Z + BOARD_HEIGHT / 2)], [], [(0, 1, 2, 3)])
    scene.collection.objects.link(board)
    camera = bpy.data.objects.get("PREVIEW_cam") or bpy.data.objects.new("PREVIEW_cam", bpy.data.cameras.new("PREVIEW_cam"))
    if camera.name not in scene.collection.objects:
        scene.collection.objects.link(camera)
    scene.camera = camera
    camera.data.lens = 32
    camera.data.clip_end = 200
    camera.location = (stand.x + 2.2, stand.y - 5.0, 4.6)
    camera.rotation_euler = (Vector((WALL_X, BOARD_Y, 4.0)) - Vector(camera.location)).to_track_quat("-Z", "Y").to_euler()
    scene.render.resolution_x, scene.render.resolution_y = 800, 600
    shots = {"draw": [0.3, 0.6]}
    for clip, moments in shots.items():
        info = clips[clip]
        frame0 = round(info["start"] * FPS) + 1
        count = round(info["duration"] * FPS)
        for moment in moments:
            scene.frame_set(frame0 + int(count * moment))
            scene.render.filepath = os.path.join(folder, f"{name}_{clip}_{int(moment * 100):02d}.png")
            bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(board, do_unlink=True)


# MARK: - Programa

def update_layout(clips):
    with open(LAYOUT) as handle:
        layout = json.load(handle)
    layout["room"]["min"][1] = NEW_FRONT
    layout["clips"].update(clips)
    layout["whiteboard"] = {
        "center": [round(WALL_X + BOARD_DEPTH / 2, 4), round(BOARD_Y, 4), BOARD_Z],
        "width": BOARD_WIDTH,
        "height": BOARD_HEIGHT,
        "depth": BOARD_DEPTH,
        "normal": [1, 0, 0],
        # Dónde se para quien dibuja (x, y, z de Blender y giro en grados): de cara a la pared (-x), con el brazo derecho
        # hacia el centro de la pizarra.
        "stand": [round(WALL_X + BOARD_DEPTH + REACH + FINGERS, 4), round(BOARD_Y + HAND_CENTER_X, 4), 0, -90],
    }
    with open(LAYOUT, "w") as handle:
        handle.write(json.dumps(layout, separators=(",", ":"), ensure_ascii=False))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    only = argv[argv.index("--only") + 1] if "--only" in argv else None
    preview = argv[argv.index("--preview") + 1] if "--preview" in argv else None
    if not (only or preview):
        extend_room()
    writing = load_writing()
    clips, last = {}, 0
    for key_name in CHARACTERS:
        if only and key_name != only:
            continue
        clips, last = build(key_name, writing, preview)
        print(f"{key_name}: clips añadidos hasta el fotograma {last}")
    if only or preview:
        return  # pruebas: ni se guarda ni se toca el JSON
    update_layout(clips)
    bpy.ops.wm.save_mainfile()
    print("Guardado; la línea de tiempo llega al fotograma", last)


main()
