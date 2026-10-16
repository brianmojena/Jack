"""Dibuja la miniatura de cada personaje de Office.blend (la que se ve al elegir avatar) en Resources/Office/Runtime.

Uso: blender -b Resources/Office/Office.blend --python scripts/office_avatar_thumbnails.py -- REMY CH31 GIRL DEADPOOL
No guarda el .blend: mueve los personajes para fotografiarlos.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources", "Office", "Runtime")
YAW = {"FRANKLIN": 180}  # ver office_export_blender.py
STAND_IDLE_FRAME = 589  # el clip «stand_idle» (de pie, quieto) empieza en 19,57 s a 30 fps


def main():
    keys = sys.argv[sys.argv.index("--") + 1:]
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "FLAT"
    scene.display.shading.color_type = "TEXTURE"
    scene.display.shading.show_shadows = False
    scene.render.film_transparent = True
    scene.render.resolution_x, scene.render.resolution_y = 300, 400
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"
    rigs = {key: bpy.data.objects[f"CHAR_{key}_rig"] for key in keys}
    for obj in bpy.data.objects:
        if obj.type in ("MESH", "ARMATURE") and not obj.name.startswith("CHAR_"):
            obj.hide_render = True
    camera_data = bpy.data.cameras.new("thumb")
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = 6.6
    camera = bpy.data.objects.new("thumb", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    scene.frame_set(STAND_IDLE_FRAME)
    for key, rig in rigs.items():
        action = bpy.data.actions[f"ALL_{key}"]
        rig.animation_data.action = action
        rig.animation_data.action_slot = action.slots[0]
        for other in bpy.data.objects:
            if other.name.startswith("CHAR_"):
                other.hide_render = not other.name.startswith(f"CHAR_{key}_")
        scene.frame_set(STAND_IDLE_FRAME)
        rig.location = (0, 0, 0)
        rig.rotation_euler = (math.radians(90), 0, math.radians(YAW.get(key, 0)))
        bpy.context.view_layer.update()
        # De frente: en la escena los personajes miran hacia -y.
        camera.location = (0, -12, 3.05)
        camera.rotation_euler = (math.radians(90), 0, 0)
        scene.render.filepath = os.path.join(OUT, f"Avatar_{key}.png")
        bpy.ops.render.render(write_still=True)
        print("miniatura", key)


main()
