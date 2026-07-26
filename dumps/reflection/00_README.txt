# PalSmith dump index (client) — written into this dump/ folder only.

Maps to dump_targets.md (this folder):
  01_datatables.txt   -> §4 content ids (item/build/pal/skill/status/tech) + column schema + §4(2e) SoundIDs
  02_reflection.txt   -> §3 life-event hooks + iconOf/mesh property fields
  03_widgets.txt      -> §5 native UI (open Build/Inventory/Paldeck before running)
  04_live_objects.txt -> §4 real build ids + §6 live pal skeletal/anim refs
  05_assets.txt       -> animation / mesh / Wwise audio / icon assets

If 02_reflection says 'UNAVAILABLE', use UE4SS's built-in Object/CXX dump or ActorDumperMod for functions.
Re-run after opening each menu to capture more UI in 03.

Run status:
  OK   01_datatables
  OK   02_reflection
  OK   03_widgets
  OK   04_live_objects
  OK   05_assets
