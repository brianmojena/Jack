"""Añade a la línea de tiempo de cada personaje (ALL_<clave>) los clips del ajedrez, sentados ante la mesa.

Uso (el .blend se guarda al terminar):

    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_clips.py

    # solo un personaje y sin guardar, con imágenes de prueba en una carpeta (para mirar cómo quedan los clips):
    blender -b --factory-startup Resources/Office/Office.blend --python scripts/office_add_clips.py -- \\
        --only REMY --preview /tmp/clips

Los FBX de Mixamo (sin piel) se leen de ~/Downloads y no se guardan en el repositorio:
 - «Sitting Victory» → `chess_win`, «Sitting Disbelief» → `chess_lose`; los dos empiezan y acaban con las manos sobre la mesa;
 - `chess_idle`: esa postura quieta (esperando el turno);
 - `chess_think`: la mano derecha sube a la barbilla (la distancia sale de «Thinking») y se queda ahí, en bucle;
 - `chess_move`: el brazo derecho se estira hacia el tablero, coge, sube y vuelve (cinemática inversa, horneada).
Cada clip se reorienta al esqueleto de cada personaje (como `retarget` de office_add_character.py) y se pega detrás de lo que
ya hay (fotograma 618 en adelante), con la cadera a la misma altura que al teclear para que se siente igual en la silla.
También añade los clips a Runtime/OfficeLayout.json.
"""
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOWNLOADS = os.path.expanduser("~/Downloads")
LAST_OLD_FRAME = 617
START = LAST_OLD_FRAME + 1
FPS = 30
HIPS = "mixamorig:Hips"
STANDING_HIPS = 1.2  # altura de las caderas (m) de las animaciones de Mixamo de pie
CHARACTERS = {"REMY": {}, "CH31": {}, "GIRL": {}, "DEADPOOL": {}, "LAMINE": {}, "FRANKLIN": {"spin": 180, "delta_torso": True}}
THINK_FRAMES, MOVE_FRAMES, IDLE_FRAMES = 96, 60, 4
SLUMP_LIMIT = 75.0  # grados que se le quitan, como mucho, a la inclinación del tronco al perder
# Altura de las manos (la mesa, 2.48, más un poco) y de la cadera sentada (con el personaje a 0.45 del suelo), en la sala.
HAND_TOP = 2.56
SEAT_HIPS = 2.13
LOOK_DOWN = 22.0  # inclinación de la cabeza hacia el tablero (grados)
TYPE_FRAME = 300  # un fotograma dentro del clip «type» (empieza en el 298)


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def import_fbx(name):
    before = set(bpy.data.objects)
    actions_before = set(bpy.data.actions)
    bpy.ops.import_scene.fbx(filepath=os.path.join(DOWNLOADS, name + ".fbx"))
    rig = next(o for o in bpy.data.objects if o not in before and o.type == "ARMATURE")
    actions = [a for a in bpy.data.actions if a not in actions_before]
    return rig, actions


def discard(rig, actions):
    for obj in [rig] + list(rig.children_recursive):
        bpy.data.objects.remove(obj, do_unlink=True)
    for action in actions:
        bpy.data.actions.remove(action)


class Solver:
    """Los giros de cada hueso del personaje para un fotograma de una animación de Mixamo (misma idea que `retarget`)."""

    def __init__(self, rig, source, spin=0.0, delta_torso=False):
        self.rig, self.source, self.delta_torso = rig, source, delta_torso
        self.order = []

        def visit(bone):
            self.order.append(bone)
            for child in bone.children:
                visit(child)

        for root in [b for b in rig.data.bones if b.parent is None]:
            visit(root)
        self.rest_t = {b.name: b.matrix_local.to_3x3() for b in rig.data.bones}
        self.turn = Matrix.Rotation(math.radians(spin), 3, "Y")
        self.rest_s = {b.name: self.turn @ source.data.bones[b.name].matrix_local.to_3x3() for b in rig.data.bones if b.name in source.data.bones}
        # Unidades del esqueleto por metro de Mixamo: las caderas del personaje miden lo mismo que 1,2 m de Mixamo.
        self.unit = rig.data.bones[HIPS].head_local.y / STANDING_HIPS

    def solve(self, frame, hips_offset=Vector((0, 0, 0)), nod=None, lean=None):
        """`nod` = (cuello, cabeza, eje): grados extra de cabeceo hacia delante, sobre el eje lateral del personaje;
        `lean` = (grados, eje): inclinación extra del tronco (negativa, hacia atrás), repartida entre las tres vértebras."""
        scene = bpy.context.scene
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        source = {pb.name: self.turn @ pb.matrix.to_3x3() for pb in self.source.pose.bones}
        hips_source = self.turn @ self.source.pose.bones[HIPS].matrix.translation.copy()
        placed, values = {}, {}
        for bone in self.order:
            if bone.name not in source:
                continue
            torso = self.delta_torso and any(word in bone.name for word in ("Shoulder", "Spine", "Neck", "Head", "Hips"))
            align = (Matrix.Identity(3) if torso else
                     (self.rest_t[bone.name] @ Vector((0, 1, 0))).rotation_difference(self.rest_s[bone.name] @ Vector((0, 1, 0))).to_matrix())
            frame_offset = self.rest_s[bone.name].inverted() @ align @ self.rest_t[bone.name]
            target = source[bone.name] @ frame_offset
            if nod and bone.name in ("mixamorig:Neck", "mixamorig:Head"):
                angle = nod[0] if bone.name.endswith("Neck") else nod[1]
                target = Matrix.Rotation(math.radians(angle), 3, nod[2]) @ target
            if lean and bone.name in ("mixamorig:Spine", "mixamorig:Spine1", "mixamorig:Spine2"):
                target = Matrix.Rotation(math.radians(lean[0] / 3), 3, lean[1]) @ target
            placed[bone.name] = target
            parent = bone.parent
            if parent is not None and parent.name in placed:
                relative = self.rest_t[parent.name].inverted() @ self.rest_t[bone.name]
                local = relative.inverted() @ placed[parent.name].inverted() @ target
            else:
                local = self.rest_t[bone.name].inverted() @ target
            location = None
            if bone.name == HIPS:
                position = hips_source * self.unit + hips_offset
                location = self.rest_t[bone.name].inverted() @ (position - bone.head_local)
            values[bone.name] = (local.to_quaternion(), location)
        return values

    def hips_position(self, frame):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        return (self.turn @ self.source.pose.bones[HIPS].matrix.translation.copy()) * self.unit


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


def axes(rig):
    """Arriba, delante y hacia la izquierda del personaje, en el espacio del esqueleto (sale de la posición de las piernas)."""
    bones = rig.data.bones
    up = Vector((0, 1, 0))
    left = (bones["mixamorig:LeftUpLeg"].head_local - bones["mixamorig:RightUpLeg"].head_local)
    left.y = 0
    left.normalize()
    forward = left.cross(up).normalized()
    return up, forward, left


def head_pitch(rig, values, up, forward):
    """Cuánto está inclinada la cabeza hacia delante (grados; negativo, hacia atrás) en la postura dada."""
    apply(rig, values)
    bpy.context.view_layer.update()
    direction = rig.pose.bones["mixamorig:Head"].matrix.to_3x3() @ Vector((0, 1, 0))
    return math.degrees(math.atan2(direction.dot(forward), direction.dot(up)))


def inverse_kinematics(rig, base, goals, label):
    """La mano derecha sigue `goals` (una posición del esqueleto por fotograma) con el brazo resuelto por cinemática inversa;
    devuelve los valores de todos los huesos de cada fotograma (el resto, como en `base`)."""
    scene = bpy.context.scene
    apply(rig, base)
    bpy.context.view_layer.update()
    forearm = rig.pose.bones["mixamorig:RightForeArm"]
    empty = bpy.data.objects.new("IK_target", None)
    scene.collection.objects.link(empty)
    empty.parent = rig
    constraint = forearm.constraints.new("IK")
    constraint.target = empty
    constraint.chain_count = 2
    constraint.iterations = 60
    constraint.use_stretch = False
    frames = []
    for goal in goals:
        empty.location = goal
        bpy.context.view_layer.update()
        values = dict(base)
        for name in ("mixamorig:RightArm", "mixamorig:RightForeArm"):
            pb = rig.pose.bones[name]
            basis = rig.convert_space(pose_bone=pb, matrix=pb.matrix, from_space="POSE", to_space="LOCAL")
            values[name] = (basis.to_quaternion(), None)
        frames.append(values)
    forearm.constraints.remove(constraint)
    bpy.data.objects.remove(empty, do_unlink=True)
    apply(rig, base)
    return frames


def raise_hands(rig, base, rise):
    """Las dos manos, rectas hacia arriba hasta `rise` (en unidades del esqueleto) por encima de las caderas; brazos por IK."""
    apply(rig, base)
    bpy.context.view_layer.update()
    hips_y = rig.pose.bones[HIPS].head.y
    empties, constraints = [], []
    for side in ("Left", "Right"):
        hand = rig.pose.bones[f"mixamorig:{side}Hand"].head.copy()
        empty = bpy.data.objects.new(f"IK_{side}", None)
        bpy.context.scene.collection.objects.link(empty)
        empty.parent = rig
        empty.location = Vector((hand.x, hips_y + rise, hand.z))
        forearm = rig.pose.bones[f"mixamorig:{side}ForeArm"]
        constraint = forearm.constraints.new("IK")
        constraint.target, constraint.chain_count, constraint.iterations, constraint.use_stretch = empty, 2, 60, False
        empties.append(empty)
        constraints.append((forearm, constraint))
    bpy.context.view_layer.update()
    values = dict(base)
    for side in ("Left", "Right"):
        for part in ("Arm", "ForeArm"):
            pb = rig.pose.bones[f"mixamorig:{side}{part}"]
            basis = rig.convert_space(pose_bone=pb, matrix=pb.matrix, from_space="POSE", to_space="LOCAL")
            values[pb.name] = (basis.to_quaternion(), None)
    for forearm, constraint in constraints:
        forearm.constraints.remove(constraint)
    for empty in empties:
        bpy.data.objects.remove(empty, do_unlink=True)
    apply(rig, base)
    return values


def build(key_name, options, sources, thinking, preview):
    rig = bpy.data.objects[f"CHAR_{key_name}_rig"]
    action = bpy.data.actions[f"ALL_{key_name}"]
    trim(action, LAST_OLD_FRAME)
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    scene = bpy.context.scene

    # La cadera sentada a la misma altura y distancia que al teclear.
    scene.frame_set(TYPE_FRAME)
    bpy.context.view_layer.update()
    typing = rig.pose.bones[HIPS].matrix.translation.copy()

    # Se resuelve todo con la animación quitada (para que no pise la postura que se prueba) y después se hornean los fotogramas.
    rig.animation_data.action = None
    spin, delta_torso = options.get("spin", 0.0), options.get("delta_torso", False)
    solver = Solver(rig, sources["lose"], spin, delta_torso)
    up, forward, left = axes(rig)
    unit = solver.unit
    offset0 = typing - solver.hips_position(1)
    # El primer fotograma de «Sitting Disbelief» mira al techo: la cabeza se baja hasta mirar el tablero.
    raw = solver.solve(1, offset0)
    fix = LOOK_DOWN - head_pitch(rig, raw, up, forward)
    nod = (fix * 0.4, fix * 0.6, left)
    idle = solver.solve(1, offset0, nod)
    # Las manos sobre la mesa: la mesa está a TABLE_TOP y la cadera sentada a SEAT_HIPS, las dos en unidades de la sala.
    idle = raise_hands(rig, idle, (HAND_TOP - SEAT_HIPS) / rig.scale.x)
    print(f"{key_name}: cabeza {LOOK_DOWN - fix:.1f}° → {LOOK_DOWN:.1f}°")

    def thinking_goals():
        # La mano derecha respecto a la cabeza cuando piensa (medido en la animación «Thinking»), en los ejes del personaje.
        delta = thinking["hand"] - thinking["head"]
        local = Vector((delta.dot(thinking["left"]), delta.dot(thinking["up"]), delta.dot(thinking["forward"])))
        apply(rig, idle)
        bpy.context.view_layer.update()
        target = rig.pose.bones["mixamorig:Head"].head.copy() + (left * local.x + up * local.y + forward * local.z) * unit
        start = rig.pose.bones["mixamorig:RightHand"].head.copy()
        goals = []
        for index in range(THINK_FRAMES):
            holding = 16 <= index < THINK_FRAMES - 16
            if index < 16:
                t = smooth(index / 15)
            elif holding:
                t = 1.0
            else:
                t = smooth((THINK_FRAMES - 1 - index) / 15)
            sway = math.sin((index - 16) / 12.0) * 0.012 * unit if holding else 0.0
            goals.append(start.lerp(target + up * sway, t))
        return goals

    def move_goals():
        apply(rig, idle)
        bpy.context.view_layer.update()
        start = rig.pose.bones["mixamorig:RightHand"].head.copy()
        out = start + forward * 0.30 * unit + up * 0.05 * unit
        grab = start + forward * 0.32 * unit - up * 0.02 * unit
        lifted = start + forward * 0.26 * unit + up * 0.12 * unit
        goals = []
        for index in range(MOVE_FRAMES):
            if index < 16:
                goals.append(start.lerp(out, smooth(index / 15)))
            elif index < 26:
                goals.append(out.lerp(grab, smooth((index - 16) / 9)))
            elif index < 42:
                goals.append(grab.lerp(lifted, smooth((index - 26) / 15)))
            else:
                goals.append(lifted.lerp(start, smooth((index - 42) / 17)))
        return goals

    pending = [("chess_idle", [idle] * IDLE_FRAMES, True),
               ("chess_think", inverse_kinematics(rig, idle, thinking_goals(), "think"), True),
               ("chess_move", inverse_kinematics(rig, idle, move_goals(), "move"), False)]
    for name in ("win", "lose"):
        source = sources[name]
        count = int(round(source.animation_data.action.frame_range[1]))
        win_solver = Solver(rig, source, spin, delta_torso)
        offset = typing - win_solver.hips_position(1)
        # La cabeza baja del todo al principio y al final (donde enlaza con la espera) y menos en lo más expresivo del clip.
        def weight(frame):
            return 0.35 + 0.65 * abs(2 * (frame - 1) / max(count - 1, 1) - 1) ** 2

        def lean(frame):
            # «Sitting Disbelief» se desploma sobre la mesa: se le quita buena parte de la inclinación.
            return (-SLUMP_LIMIT * (1 - weight(frame)) / 0.65, left) if name == "lose" else None
        pending.append(("chess_" + name, [win_solver.solve(frame, offset, (nod[0] * weight(frame), nod[1] * weight(frame), left), lean(frame))
                                           for frame in range(1, count + 1)], False))

    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    clips, previous, cursor = {}, {}, START
    for name, frames, loop in pending:
        for offset, values in enumerate(frames):
            key(rig, values, cursor + offset, previous)
        clips[name] = {"start": round((cursor - 1) / FPS, 5), "duration": round((len(frames) - 1) / FPS, 5), "loop": loop}
        cursor += len(frames)
    if preview:
        render_preview(rig, key_name, clips, preview, action)
    return clips, cursor - 1


# MARK: - Imágenes de prueba

def render_preview(rig, name, clips, folder, action):
    """Imágenes del personaje sentado en el escritorio de Remy, en varios momentos de cada clip (solo para revisar)."""
    os.makedirs(folder, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    for obj in bpy.data.objects:
        if obj.type == "MESH" and obj.name.startswith("ROOM_merged"):
            obj.hide_render = True
        if obj.name.startswith("CHAR_") and obj is not rig and not obj.name.startswith(f"CHAR_{name}"):
            obj.hide_render = True
    # Sentado donde irá en la mesa (asiento oeste, mirando al este), con la silla de Remy en la misma posición relativa.
    seat = Vector((4.45, -6.2, 0.45))
    rig.location = seat
    # Como al exportar: el giro extra de los esqueletos que vienen girados de fábrica (YAW de office_export_blender.py).
    rig.rotation_euler = (math.radians(90), 0, math.radians(90 + (180 if name == "FRANKLIN" else 0)))
    chair = bpy.data.objects["PROP_gaming_chair_02"]
    if chair.animation_data:
        chair.animation_data.action = None
    bpy.context.view_layer.update()
    world = chair.matrix_world.copy()
    chair.parent = None
    chair.matrix_world = world
    tucked = world.translation - Vector((0, -1, 0)) * 1.5
    relative = Vector((-0.78, 2.18, 0)) - Vector((tucked.x, tucked.y, 0))
    delta = math.radians(90 - 180)
    turn = Matrix.Rotation(delta, 3, "Z")
    placed = Vector((seat.x, seat.y, 0)) - turn @ relative
    chair.rotation_euler.z += delta
    chair.location = (placed.x, placed.y, world.translation.z)
    camera = bpy.data.objects.get("PREVIEW_cam") or bpy.data.objects.new("PREVIEW_cam", bpy.data.cameras.new("PREVIEW_cam"))
    if camera.name not in scene.collection.objects:
        scene.collection.objects.link(camera)
    scene.camera = camera
    camera.data.lens = 38
    camera.location = (5.6, -12.5, 4.2)
    camera.rotation_euler = (Vector((5.4, -6.2, 2.9)) - Vector(camera.location)).to_track_quat("-Z", "Y").to_euler()
    scene.render.resolution_x, scene.render.resolution_y = 700, 700
    shots = {"chess_idle": [0], "chess_think": [0.25, 0.5], "chess_move": [0.2, 0.45, 0.7], "chess_win": [0.3, 0.6], "chess_lose": [0.3, 0.6]}
    for clip, moments in shots.items():
        info = clips[clip]
        frame0 = round(info["start"] * FPS) + 1
        count = round(info["duration"] * FPS)
        for moment in moments:
            scene.frame_set(frame0 + int(count * moment))
            scene.render.filepath = os.path.join(folder, f"{name}_{clip}_{int(moment * 100):02d}.png")
            bpy.ops.render.render(write_still=True)


# MARK: - Programa

def measure_thinking():
    """Dónde está la mano derecha respecto a la cabeza mientras piensa, en los ejes del esqueleto de Mixamo."""
    rig, actions = import_fbx("Thinking")
    scene = bpy.context.scene
    samples = []
    for frame in range(45, 81, 4):
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        samples.append((rig.pose.bones["mixamorig:Head"].head.copy(), rig.pose.bones["mixamorig:RightHand"].head.copy()))
    head = sum((s[0] for s in samples), Vector()) / len(samples)
    hand = sum((s[1] for s in samples), Vector()) / len(samples)
    up, forward, left = axes(rig)
    discard(rig, actions)
    return {"head": head, "hand": hand, "up": up, "forward": forward, "left": left}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    only = argv[argv.index("--only") + 1] if "--only" in argv else None
    preview = argv[argv.index("--preview") + 1] if "--preview" in argv else None
    thinking = measure_thinking()
    sources = {}
    for name, file in (("win", "Sitting Victory"), ("lose", "Sitting Disbelief")):
        sources[name] = import_fbx(file)
    rigs = {name: rig for name, (rig, _) in sources.items()}
    clips, last = {}, 0
    for key_name, options in CHARACTERS.items():
        if only and key_name != only:
            continue
        clips, last = build(key_name, options, rigs, thinking, preview)
        print(f"{key_name}: clips añadidos hasta el fotograma {last}")
    if only or preview:
        return  # pruebas: ni se guarda ni se toca el JSON
    for rig, actions in sources.values():
        discard(rig, actions)
    path = os.path.join(ROOT, "Resources", "Office", "Runtime", "OfficeLayout.json")
    with open(path) as handle:
        layout = json.load(handle)
    layout["clips"].update(clips)
    with open(path, "w") as handle:
        json.dump(layout, handle, separators=(",", ":"), ensure_ascii=False)
    for obj in bpy.data.objects:
        if obj.type == "ARMATURE" and obj.name.startswith("CHAR_"):
            bpy.context.view_layer.update()
    bpy.ops.wm.save_mainfile()
    print("Clips guardados; la línea de tiempo llega al fotograma", last)


main()
