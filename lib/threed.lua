-- ============================================================
--  threed - small "real" 3D math helper library
--
--  This is genuine 3D geometry (not a faked 2D shading trick):
--  points on an actual unit sphere, rotated with real rotation
--  matrices around the X/Y/Z axes, projected to 2D screen space,
--  and shaded per-point with real Lambertian lighting
--  (dot(normal, lightDirection)).
--
--  Used by moonsat (spinning moon) and satellites (spinning Earth
--  + orbiting satellite markers) to render an actual 3D scene onto
--  a text terminal / monitor.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local M = {}

-- ---------------------------------------------------------------
-- Vectors
-- ---------------------------------------------------------------

function M.vec3(x, y, z)
  return { x = x, y = y, z = z }
end

function M.add(a, b)
  return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function M.scale(v, s)
  return { x = v.x * s, y = v.y * s, z = v.z * s }
end

function M.length(v)
  return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function M.normalize(v)
  local len = M.length(v)
  if len < 1e-9 then
    return { x = 0, y = 0, z = 0 }
  end
  return { x = v.x / len, y = v.y / len, z = v.z / len }
end

function M.dot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

-- ---------------------------------------------------------------
-- Rotation matrices (angles in radians, right-handed)
-- ---------------------------------------------------------------

function M.rotateX(v, angle)
  local c, s = math.cos(angle), math.sin(angle)
  return { x = v.x, y = v.y * c - v.z * s, z = v.y * s + v.z * c }
end

function M.rotateY(v, angle)
  local c, s = math.cos(angle), math.sin(angle)
  return { x = v.x * c + v.z * s, y = v.y, z = -v.x * s + v.z * c }
end

function M.rotateZ(v, angle)
  local c, s = math.cos(angle), math.sin(angle)
  return { x = v.x * c - v.y * s, y = v.x * s + v.y * c, z = v.z }
end

-- ---------------------------------------------------------------
-- Sphere sampling
-- ---------------------------------------------------------------

-- Returns a list of unit-sphere surface points (a point on a unit
-- sphere is also its own outward normal), sampled on a
-- latitude/longitude grid. latSteps/lonSteps control resolution.
function M.sphere(latSteps, lonSteps)
  local pts = {}
  for i = 0, latSteps do
    local theta = math.pi * (i / latSteps) -- 0 (north pole) .. pi (south pole)
    local y = math.cos(theta)
    local ringR = math.sin(theta)
    for j = 0, lonSteps - 1 do
      local phi = 2 * math.pi * (j / lonSteps)
      local x = ringR * math.cos(phi)
      local z = ringR * math.sin(phi)
      pts[#pts + 1] = { x = x, y = y, z = z }
    end
  end
  return pts
end

-- ---------------------------------------------------------------
-- Projection
-- ---------------------------------------------------------------

-- Simple scaled orthographic projection (reads well for the small
-- radii text terminals deal with). Returns screen-space offsets
-- from the sphere's center (dx, dy) and the point's depth (z,
-- camera-space) for backface culling / draw ordering.
-- Screen Y grows downward, so we flip the vertical axis here.
function M.project(v, scaleX, scaleY)
  return v.x * scaleX, -v.y * scaleY, v.z
end

-- Lambert shading: how directly a surface normal faces the light.
-- Returns a value roughly in [0, 1] (clamped at 0 so unlit points
-- read as fully dark rather than negative).
function M.lambert(normal, lightDir)
  local d = M.dot(normal, lightDir)
  if d < 0 then d = 0 end
  return d
end

-- ---------------------------------------------------------------
-- Rasterizing a sphere's point cloud onto a text grid
-- ---------------------------------------------------------------

-- Rotates every point in `pts` by rotY (around Y) then rotX (around
-- X), culls the far side (camera looks down +z, so points with
-- rotated z <= 0 are hidden), projects the rest to integer screen
-- cells around (cx, cy), and keeps only the closest point per cell
-- (a simple z-buffer) so overlapping samples don't fight each other.
--
-- Returns a plain array of { sx, sy, shade } - one entry per visible
-- screen cell, ready to be drawn with a shading gradient string.
--
-- lightDir must already be a normalized vec3.
--
-- extras (optional): an array parallel to `pts` (same indices) with
-- any extra per-point data a caller wants carried through to the
-- output (e.g. a land/ocean classification for coloring a planet).
-- When given, each output cell also has an `extra` field.
function M.rasterizeSphere(pts, rotY, rotX, lightDir, scaleX, scaleY, cx, cy, w, h, extras)
  local buffer = {}
  local order = {}

  for i, p in ipairs(pts) do
    local r = M.rotateX(M.rotateY(p, rotY), rotX)
    if r.z > 0 then
      local dx, dy, z = M.project(r, scaleX, scaleY)
      local sx = cx + math.floor(dx + 0.5)
      local sy = cy + math.floor(dy + 0.5)
      if sx >= 1 and sx <= w and sy >= 1 and sy <= h then
        local key = sx * 100000 + sy
        local existing = buffer[key]
        if not existing or z > existing.z then
          if not existing then
            order[#order + 1] = key
          end
          buffer[key] = {
            sx = sx, sy = sy, z = z,
            shade = M.lambert(r, lightDir),
            extra = extras and extras[i] or nil,
          }
        end
      end
    end
  end

  local out = {}
  for _, key in ipairs(order) do
    local cell = buffer[key]
    out[#out + 1] = { sx = cell.sx, sy = cell.sy, shade = cell.shade, extra = cell.extra }
  end
  return out
end

return M


