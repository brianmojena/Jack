"""Añade a Office.blend un personaje rigged con Mixamo, listo para exportar con office_export_blender.py.

Uso (el .blend se guarda al terminar):

    blender -b Resources/Office/Office.blend --python scripts/office_add_character.py -- \\
        DEADPOOL ~/Downloads/personaje.fbx ~/Downloads/textura.png GIRL

    blender -b Resources/Office/Office.blend --python scripts/office_add_character.py -- \\
        LAMINE ~/Downloads/lamine.fbx ~/Downloads/carpeta-de-texturas GIRL --drop mouth,otra_malla

    blender -b Resources/Office/Office.blend --python scripts/office_add_character.py -- \\
        FRANKLIN ~/Downloads/franklin.fbx ~/Downloads/carpeta-de-texturas GIRL \\
        --meshmap "Object001=head.png,Object002=body.png"

Argumentos: clave del personaje (mayúsculas), FBX de Mixamo (T-pose), la textura de color (un PNG) o una carpeta con las
texturas (para un modelo con varias mallas y materiales) y la clave de un personaje que ya esté en el archivo, del que se
copia la línea de tiempo con todos los clips (ALL_<clave>). Con `--copy` las animaciones se copian tal cual aunque los huesos del modelo estén girados (un esqueleto girado 180° sobre el eje
vertical, como el de un modelo que mira hacia atrás en el FBX, hace igual el movimiento pero girado: se corrige con YAW en
office_export_blender.py); con `--delta-torso` el tronco, los hombros y la cabeza copian solo el giro del donante (sin alinearlos con él: evita hombros
subidos cuando el esqueleto del modelo tiene las clavículas más bajas); con `--flip` se gira el modelo (malla y esqueleto) 180° sobre su eje vertical (para los que miran hacia atrás respecto a lo que Mixamo
supone: las rodillas doblarían hacia atrás); con `--drop` se quitan mallas por su nombre; con `--meshmap` se le da a cada malla sin material (así llegan algunos modelos
de Mixamo) el archivo de textura que le toca, buscado dentro de la carpeta (nombre de la malla=archivo, separados por comas).

Lo que hace:
 - importa el FBX como CHAR_<clave>_rig y CHAR_<clave>_<malla>, apartado de la sala;
 - le baja el origen a los pies (algunos modelos de Mixamo llegan centrados en el cuerpo);
 - lo escala para que sus caderas queden a la misma altura que las de los demás (así encaja en los mismos sofás y sillas);
 - le pone las texturas, que Mixamo no conserva o deja en formatos y rutas que no valen: cada material se rehace con su imagen
   de color (y su transparencia, en el pelo y la boca), guardada a 1024 píxeles como mucho en Resources/Office/Textures/<clave>;
 - copia ALL_<donante> como ALL_<clave>, ajustando el desplazamiento de las caderas a las proporciones del nuevo personaje
   (los giros de los huesos valen tal cual: todos los rigs de Mixamo tienen el mismo esqueleto).
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

HIPS_HEIGHT = 2.96  # altura de las caderas, en unidades de la escena, de los personajes que ya hay
MAX_TEXTURE = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def base_image(material):
    """La imagen que alimenta el color base de un material (buscando río arriba entre sus nodos), si tiene datos."""
    if not material or not material.use_nodes:
        return None
    shader = next((n for n in material.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if shader is None or not shader.inputs["Base Color"].links:
        return None
    pending = [shader.inputs["Base Color"].links[0].from_node]
    seen = set()
    while pending:
        node = pending.pop(0)
        if node in seen:
            continue
        seen.add(node)
        if node.type == "TEX_IMAGE" and node.image and node.image.size[0] > 0:
            return node.image
        pending += [link.from_node for socket in node.inputs for link in socket.links]
    return None


def flat_color(material):
    shader = next((n for n in material.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None) if material and material.use_nodes else None
    return tuple(shader.inputs["Base Color"].default_value) if shader else (0.5, 0.5, 0.5, 1.0)


def saved_texture(image, texture_dir, folder, key):
    """Guarda la imagen como PNG de 1024 como mucho y la devuelve cargada. Los datos que trae el propio FBX mandan; solo si
    no hay (imagen sin datos) se busca en la carpeta un PNG con el mismo nombre (Mixamo suele dejar .dds)."""
    stem = os.path.splitext(os.path.basename(image.name))[0].split(".")[0]
    source = image
    if image.size[0] == 0:
        candidate = os.path.join(texture_dir, f"{stem}.png")
        if os.path.isfile(candidate):
            source = bpy.data.images.load(candidate, check_existing=False)
    copy = source.copy()
    width, height = copy.size
    if max(width, height) > MAX_TEXTURE:
        factor = MAX_TEXTURE / max(width, height)
        copy.scale(max(1, int(width * factor)), max(1, int(height * factor)))
    os.makedirs(folder, exist_ok=True)
    name = f"{key}_{stem.replace(' ', '_')}"
    path = os.path.join(folder, f"{name}.png")
    copy.filepath_raw = path
    copy.file_format = "PNG"
    copy.save()
    bpy.data.images.remove(copy)
    result = bpy.data.images.load(path, check_existing=False)
    result.name = name
    return result


def rebuild_material(old, key, name, texture_dir, folder, cache):
    image = base_image(old)
    material = bpy.data.materials.new(f"{key}_{name}")
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    shader = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
    shader.inputs["Roughness"].default_value = 0.6
    if image is None:
        shader.inputs["Base Color"].default_value = flat_color(old)
        return material
    if image.name not in cache:
        cache[image.name] = saved_texture(image, texture_dir, folder, key)
    texture = cache[image.name]
    picture = nodes.new("ShaderNodeTexImage")
    picture.image = texture
    links.new(picture.outputs["Color"], shader.inputs["Base Color"])
    # El pelo y la boca llevan su transparencia en el canal alfa de la imagen.
    if any(word in texture.name.lower() for word in ("alp", "oral", "hair")):
        links.new(picture.outputs["Alpha"], shader.inputs["Alpha"])
    return material


def find_file(folder, filename):
    for base, _, files in os.walk(folder):
        if filename in files:
            return os.path.join(base, filename)
    return None


def material_from_file(key, name, path, folder):
    """Un material con una imagen de color de un archivo (a 1024 píxeles como mucho)."""
    image = bpy.data.images.load(path, check_existing=False)
    texture = saved_texture(image, os.path.dirname(path), folder, key)
    bpy.data.images.remove(image)
    material = bpy.data.materials.new(f"{key}_{name}")
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    shader = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
    shader.inputs["Roughness"].default_value = 0.6
    picture = nodes.new("ShaderNodeTexImage")
    picture.image = texture
    links.new(picture.outputs["Color"], shader.inputs["Base Color"])
    return material


def retarget(rig, donor_rig, donor_action, name, delta_torso=False, spin=0.0):
    """Copia la animación del donante a un rig cuyos huesos tienen otro giro de reposo (el eje de cada hueso cambia de un
    modelo a otro, y con él lo que significa un giro). Para cada fotograma, cada hueso del nuevo rig apunta adonde apuntaba
    el del donante; de ahí salen los giros locales, en el orden de la jerarquía."""
    donor_rig.animation_data.action = donor_action
    donor_rig.animation_data.action_slot = donor_action.slots[0]
    action = bpy.data.actions.new(name)
    rig.animation_data_create()
    rig.animation_data.action = action
    order = []
    def visit(bone):
        order.append(bone)
        for child in bone.children:
            visit(child)
    for root in [b for b in rig.data.bones if b.parent is None]:
        visit(root)
    rest_t = {b.name: b.matrix_local.to_3x3() for b in rig.data.bones}
    # Con `spin`, el donante se gira antes sobre el eje vertical, para compararlo con un esqueleto que viene girado de fábrica.
    turn = Matrix.Rotation(math.radians(spin), 3, "Y")
    rest_s = {b.name: turn @ donor_rig.data.bones[b.name].matrix_local.to_3x3() for b in rig.data.bones if b.name in donor_rig.data.bones}
    ratio = rig.data.bones["mixamorig:Hips"].head_local.y / donor_rig.data.bones["mixamorig:Hips"].head_local.y
    for pb in rig.pose.bones:
        pb.rotation_mode = "QUATERNION"
    scene = bpy.context.scene
    start, end = (int(round(v)) for v in donor_action.frame_range)
    for frame in range(start, end + 1):
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        source = {pb.name: turn @ pb.matrix.to_3x3() for pb in donor_rig.pose.bones}
        hips_source = turn @ donor_rig.pose.bones["mixamorig:Hips"].matrix.translation.copy()
        placed = {}
        for bone in order:
            if bone.name not in source:
                continue
            # El hueso del nuevo rig mira, en reposo, algo distinto al del donante (una pose de brazos más abierta o más
            # cerrada): se gira primero hasta que apunten igual, y así los brazos hacen lo mismo que los del donante. Con
            # `delta_torso`, el tronco, los hombros y la cabeza no se alinean: solo copian cuánto giró el hueso del donante.
            torso = delta_torso and any(word in bone.name for word in ("Shoulder", "Spine", "Neck", "Head", "Hips"))
            align = Matrix.Identity(3) if torso else (rest_t[bone.name] @ Vector((0, 1, 0))).rotation_difference(rest_s[bone.name] @ Vector((0, 1, 0))).to_matrix()
            frame_offset = rest_s[bone.name].inverted() @ align @ rest_t[bone.name]
            target = source[bone.name] @ frame_offset
            placed[bone.name] = target
            parent = bone.parent
            if parent is not None and parent.name in placed:
                relative = rest_t[parent.name].inverted() @ rest_t[bone.name]
                local = relative.inverted() @ placed[parent.name].inverted() @ target
            else:
                local = rest_t[bone.name].inverted() @ target
            pb = rig.pose.bones[bone.name]
            pb.rotation_quaternion = local.to_quaternion()
            pb.keyframe_insert("rotation_quaternion", frame=frame)
            if bone.name == "mixamorig:Hips":
                position = hips_source * ratio
                pb.location = rest_t[bone.name].inverted() @ (position - bone.head_local)
                pb.keyframe_insert("location", frame=frame)
    scene.frame_set(start)
    return action


def main():
    args = sys.argv[sys.argv.index("--") + 1:]
    drop = []
    if "--drop" in args:
        index = args.index("--drop")
        drop = args[index + 1].split(",")
        del args[index:index + 2]
    flip = "--flip" in args
    if flip:
        args.remove("--flip")
    force_copy = "--copy" in args
    if force_copy:
        args.remove("--copy")
    spin = 0.0
    if "--spin" in args:
        index = args.index("--spin")
        spin = float(args[index + 1])
        del args[index:index + 2]
    delta_torso = "--delta-torso" in args
    if delta_torso:
        args.remove("--delta-torso")
    meshmap = {}
    if "--meshmap" in args:
        index = args.index("--meshmap")
        meshmap = dict(pair.split("=", 1) for pair in args[index + 1].split(","))
        del args[index:index + 2]
    key, fbx, texture, donor = args[:4]
    fbx, texture = os.path.expanduser(fbx), os.path.expanduser(texture)
    before = set(bpy.data.objects.keys())
    bpy.ops.import_scene.fbx(filepath=fbx)
    new = [bpy.data.objects[name] for name in bpy.data.objects.keys() if name not in before]
    rig = next(o for o in new if o.type == "ARMATURE")
    mesh_names = [o.name for o in new if o.type == "MESH" and o.name not in drop]
    for name in drop:
        if name in bpy.data.objects:
            bpy.data.objects.remove(bpy.data.objects[name], do_unlink=True)
    meshes = [bpy.data.objects[name] for name in mesh_names]
    rig.name = rig.data.name = f"CHAR_{key}_rig"
    for index, mesh in enumerate(meshes):
        mesh.name = f"CHAR_{key}_{mesh.name}" if len(meshes) > 1 else f"CHAR_{key}_Body"

    # Algunos modelos traen escalas y giros enormes en cada malla: se aplican para que quede una sola unidad.
    bpy.ops.object.select_all(action="DESELECT")
    for mesh in meshes:
        mesh.select_set(True)
        bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    if flip:
        # El modelo mira hacia atrás: malla y esqueleto se giran juntos 180° sobre el eje vertical. Lo que era la izquierda queda a
        # la derecha, así que los huesos (y con ellos sus grupos de vértices) intercambian Left y Right.
        bpy.context.view_layer.update()
        spin = Matrix.Rotation(math.pi, 4, "Y")
        to_local = rig.matrix_world.inverted()
        for mesh in meshes:
            matrix = mesh.matrix_world
            inverse = matrix.inverted()
            for vertex in mesh.data.vertices:
                vertex.co = inverse @ (rig.matrix_world @ (spin @ (to_local @ (matrix @ vertex.co))))
            mesh.data.update()
        bpy.context.view_layer.objects.active = rig
        bpy.ops.object.mode_set(mode="EDIT")
        edit = rig.data.edit_bones
        for bone in edit:
            bone.use_connect = False
        for bone in edit:
            bone.matrix = spin @ bone.matrix
        swapped = {}
        for bone in edit:
            if "Left" in bone.name:
                swapped[bone.name] = bone.name.replace("Left", "Right")
            elif "Right" in bone.name:
                swapped[bone.name] = bone.name.replace("Right", "Left")
        for old in swapped:
            edit[old].name = f"FLIP_{old}"
        for old, new in swapped.items():
            edit[f"FLIP_{old}"].name = new
        bpy.ops.object.mode_set(mode="OBJECT")

    # Los pies en el origen: la malla y los huesos suben juntos lo que haga falta (las animaciones son relativas al reposo,
    # no les afecta). Mixamo deja el modelo tal como se subió, a veces centrado en el cuerpo.
    bpy.context.view_layer.update()
    inverse = rig.matrix_world.inverted()
    feet = min((inverse @ (mesh.matrix_world @ v.co)).y for mesh in meshes for v in mesh.data.vertices)
    hips = rig.data.bones["mixamorig:Hips"].head_local.y
    if abs(feet) > 0.05 * hips:
        for mesh in meshes:
            offset = mesh.matrix_world.inverted().to_3x3() @ (rig.matrix_world.to_3x3() @ Vector((0, feet, 0)))
            for vertex in mesh.data.vertices:
                vertex.co -= offset
            mesh.data.update()
        bpy.context.view_layer.objects.active = rig
        bpy.ops.object.mode_set(mode="EDIT")
        # Con los huesos encadenados, mover la cola del padre ya mueve la cabeza del hijo: se sueltan antes de moverlos.
        for bone in rig.data.edit_bones:
            bone.use_connect = False
        for bone in rig.data.edit_bones:
            bone.head.y -= feet
            bone.tail.y -= feet
        bpy.ops.object.mode_set(mode="OBJECT")

    # Caderas a la altura de los demás.
    hips = rig.data.bones["mixamorig:Hips"].head_local.y
    scale = HIPS_HEIGHT / hips
    rig.scale = (scale, scale, scale)
    rig.rotation_euler = (math.radians(90), 0, 0)
    rig.location = (25, 0, 0)

    # Las texturas.
    if os.path.isdir(texture):
        folder = os.path.join(ROOT, "Resources", "Office", "Textures", key.title())
        cache = {}
        for mesh in meshes:
            original = mesh.name.split("_", 2)[-1]
            if not mesh.data.materials and original in meshmap:
                path = find_file(texture, meshmap[original])
                if path is None:
                    raise SystemExit(f"no encuentro la textura {meshmap[original]} para {original}")
                mesh.data.materials.append(material_from_file(key, original, path, folder))
                continue
            # Se cambia cada material en su sitio: vaciar la lista de materiales de una malla reinicia el material de cada cara.
            for index, material in enumerate(list(mesh.data.materials)):
                mesh.data.materials[index] = rebuild_material(material, key, f"{mesh.name.split('_', 2)[-1]}_{index}", texture, folder, cache)
    else:
        image = bpy.data.images.load(texture, check_existing=True)
        image.name = f"{key}_albedo"
        material = bpy.data.materials.new(f"{key}_skin")
        material.use_nodes = True
        nodes, links = material.node_tree.nodes, material.node_tree.links
        shader = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
        picture = nodes.new("ShaderNodeTexImage")
        picture.image = image
        links.new(picture.outputs["Color"], shader.inputs["Base Color"])
        shader.inputs["Roughness"].default_value = 0.6
        for mesh in meshes:
            mesh.data.materials.clear()
            mesh.data.materials.append(material)

    # La línea de tiempo con todos los clips, copiada del donante y ajustada a las caderas del nuevo personaje.
    donor_rig = bpy.data.objects[f"CHAR_{donor}_rig"]
    donor_action = bpy.data.actions[f"ALL_{donor}"]
    ratio = hips / donor_rig.data.bones["mixamorig:Hips"].head_local.y
    differences = [
        math.degrees((donor_rig.data.bones[b.name].matrix_local.to_3x3().inverted() @ b.matrix_local.to_3x3()).to_quaternion().angle)
        for b in rig.data.bones if b.name in donor_rig.data.bones
    ]
    if not force_copy and sum(differences) / len(differences) > 10:
        # Los ejes de los huesos no coinciden con los del donante: hay que reorientar cada giro (ver `retarget`).
        action = retarget(rig, donor_rig, donor_action, f"ALL_{key}", delta_torso, spin)
    else:
        action = donor_action.copy()
        action.name = f"ALL_{key}"
        for layer in action.layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    for curve in bag.fcurves:
                        if not curve.data_path.endswith(".location"):
                            continue
                        for point in curve.keyframe_points:
                            point.co.y *= ratio
                            point.handle_left.y *= ratio
                            point.handle_right.y *= ratio
                        curve.update()
        rig.animation_data_create()
    rig.animation_data.action = action
    if action.slots:
        rig.animation_data.action_slot = action.slots[0]
    bpy.ops.wm.save_mainfile()
    print(f"{key}: caderas {hips:.4f} → {HIPS_HEIGHT}, escala {scale:.4f}, ajuste de caderas {ratio:.6f}, {len(meshes)} mallas")


main()
