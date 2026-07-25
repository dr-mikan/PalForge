-- PalForge core.mesh.static: the `kind = "static"` mesh backend — a UE-authored
-- UStaticMesh asset swapped onto the actor via a UStaticMeshComponent. TODO STUB:
-- extends the base renderer and no-ops until a real asset path is wired. Registered
-- on the facade under kind "static" so the extension path is visible.
local Renderer = require("palforge.core.mesh.base.renderer")

local StaticMesh = Renderer:extend("StaticMeshRenderer")

function StaticMesh:attach(actor, spec)
    -- TODO: create a UStaticMeshComponent, load spec.asset (a UStaticMesh object
    --       path) via StaticFindObject/LoadObject, SetStaticMesh, then attach + scale.
    return false
end

return StaticMesh
