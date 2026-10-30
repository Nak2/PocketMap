PocketMap = PocketMap or {}
PocketMap.Movement = {}

do
    local band                              = bit.band
    local bor                               = bit.bor
    local sqrt                              = math.sqrt
    local sin                               = math.sin
    local cos                               = math.cos
    local rad                               = math.rad
    local min                               = math.min
    local max                               = math.max
    local abs                               = math.abs

    local TraceHull                         = util.TraceHull
    local PointContents                     = util.PointContents
    local TickInterval                      = engine.TickInterval

    local BTN_JUMP                          = IN_JUMP or 2
    local BTN_DUCK                          = IN_DUCK or 4
    local BTN_FORWARD                       = IN_FORWARD or 8
    local BTN_BACK                          = IN_BACK or 16
    local BTN_MOVELEFT                      = IN_MOVELEFT or 512
    local BTN_MOVERIGHT                     = IN_MOVERIGHT or 1024
    local BTN_SPEED                         = IN_SPEED or 131072

    local MT_WALK                           = MOVETYPE_WALK or 2
    local MT_LADDER                         = MOVETYPE_LADDER or 9
    local MT_NOCLIP                         = MOVETYPE_NOCLIP or 8

    local FL_FROZEN_L                       = FL_FROZEN or 64
    local FL_ONTRAIN_L                      = FL_ONTRAIN or 16

    local CONTENTS_EMPTY_L                  = CONTENTS_EMPTY or 0
    local CONTENTS_LADDER_L                 = CONTENTS_LADDER or 0x20000000
    local CONTENTS_WATER_L                  = CONTENTS_WATER or 0x20
    local CONTENTS_SLIME_L                  = CONTENTS_SLIME or 0x10
    local CONTENTS_MOVEABLE_L               = CONTENTS_MOVEABLE or 0x4000

    local MASK_SOLID_L                      = MASK_SOLID or 0xFFFFFFFF
    local MASK_PLAYERSOLID_L                = MASK_PLAYERSOLID or MASK_SOLID_L
    local MASK_WATER_L                      = MASK_WATER or bor(CONTENTS_WATER_L, CONTENTS_SLIME_L, CONTENTS_MOVEABLE_L)
    local LADDER_MASK_L                     = bor(MASK_PLAYERSOLID_L, CONTENTS_LADDER_L)
    local COLLISION_GROUP_PLAYER_MOVEMENT_L = COLLISION_GROUP_PLAYER_MOVEMENT or COLLISION_GROUP_PLAYER or 8

    local WALK_SPEED_FALLBACK               = 220
    local SPRINT_SPEED_FALLBACK             = 320
    local DUCK_SPEED_MUL_FALLBACK           = 0.34

    local ACCEL_FALLBACK                    = 10
    local AIR_ACCEL_FALLBACK                = 10
    local AIR_WISH_CAP                      = 30
    local FRICTION_FALLBACK                 = 4
    local STOP_SPEED_FALLBACK               = 100

    local GRAVITY_FALLBACK                  = 600
    local WATER_ACCEL                       = 10
    local WATER_FRICTION_MUL                = 1.35
    local WATER_GRAVITY_MUL                 = 0.25
    local WATER_JUMP_SPEED                  = 100
    local WATER_SINK_SPEED                  = 60

    local MAX_BUMPS                         = 4
    local MAX_CLIP_PLANES                   = 5
    local OVERBOUNCE                        = 1.0
    local VELOCITY_EPSILON                  = 0.0001

    local STEP_HEIGHT                       = 18
    local STEP_DOWN                         = 18
    local GROUND_NORMAL                     = 0.70
    local GROUND_SNAP                       = 2
    local SURFACE_EPSILON                   = 0.03125
    local ZERO_FRACTION_EPSILON             = 0.001
    local NON_JUMP_VELOCITY                 = 140

    local LADDER_CHECK_DIST                 = 4
    local LADDER_SPEED                      = 200
    local LADDER_DISMOUNT                   = 270

    local AUTO_BHOP                         = true

    local STAND_MINS                        = Vector(-16, -16, 0)
    local STAND_MAXS                        = Vector(16, 16, 72)
    local DUCK_MINS                         = Vector(-16, -16, 0)
    local DUCK_MAXS                         = Vector(16, 16, 36)

    local trStart                           = Vector()
    local trEnd                             = Vector()
    local pointVec                          = Vector()

    local traceData                         = {
        start = trStart,
        endpos = trEnd,
        mins = STAND_MINS,
        maxs = STAND_MAXS,
        mask = MASK_PLAYERSOLID_L,
        collisiongroup = COLLISION_GROUP_PLAYER_MOVEMENT_L,
        filter = nil
    }

    local planeNx                           = {}
    local planeNy                           = {}
    local planeNz                           = {}

    local states                            = setmetatable({}, { __mode = "k" })
    local context

    local cvGravity                         = GetConVar and GetConVar("sv_gravity")
    local cvFriction                        = GetConVar and GetConVar("sv_friction")
    local cvAccelerate                      = GetConVar and GetConVar("sv_accelerate")
    local cvAirAccelerate                   = GetConVar and GetConVar("sv_airaccelerate")
    local cvStopSpeed                       = GetConVar and GetConVar("sv_stopspeed")
    local cvMaxVelocity                     = GetConVar and GetConVar("sv_maxvelocity")
    local cvNoclipSpeed                     = GetConVar and GetConVar("sv_noclipspeed")
    local cvNoclipAccelerate                = GetConVar and GetConVar("sv_noclipaccelerate")

    local function cvar_float(cv, fallback)
        if cv and cv.GetFloat then
            return cv:GetFloat()
        end

        return fallback
    end

    local function hull_for_duck(ducking)
        if ducking then
            return DUCK_MINS, DUCK_MAXS
        end

        return STAND_MINS, STAND_MAXS
    end

    local function fake_nohit_trace(out, ex, ey, ez)
        out = out or {}

        local hitPos = out.HitPos
        if not hitPos then
            hitPos = Vector()
            out.HitPos = hitPos
        end

        hitPos.x, hitPos.y, hitPos.z = ex, ey, ez

        local normal = out.HitNormal
        if not normal then
            normal = Vector(0, 0, 1)
            out.HitNormal = normal
        else
            normal.x, normal.y, normal.z = 0, 0, 1
        end

        out.Fraction = 1
        out.fraction = 1

        out.Hit = false
        out.hit = false
        out.HitWorld = false

        out.StartSolid = false
        out.startsolid = false

        out.AllSolid = false
        out.allsolid = false

        out.Entity = NULL
        out.HitEntity = NULL

        out.Contents = CONTENTS_EMPTY_L
        out.contents = CONTENTS_EMPTY_L

        out.EndPos = hitPos
        out.endpos = hitPos
        out.Normal = normal

        return out
    end

    local function trace_hull(ply, sx, sy, sz, ex, ey, ez, mins, maxs, mask, out)
        if context then
            -- GMod Vectors store floats. Rounding each intermediate slide trace
            -- pushes tangent surf motion back into the ramp before it is tested.
            return context:TraceHull({x = sx, y = sy, z = sz}, {x = ex, y = ey, z = ez}, mins, maxs, mask, out)
        end
        if ply:GetMoveType() == MT_NOCLIP then
            return fake_nohit_trace(out, ex, ey, ez)
        end

        trStart.x, trStart.y, trStart.z = sx, sy, sz
        trEnd.x, trEnd.y, trEnd.z = ex, ey, ez

        traceData.mins = mins
        traceData.maxs = maxs
        traceData.mask = mask or MASK_PLAYERSOLID_L
        traceData.filter = ply
        traceData.collisiongroup = COLLISION_GROUP_PLAYER_MOVEMENT_L
        traceData.output = out

        local result = TraceHull(traceData)
        return result or out
    end

    local function point_contents(x, y, z)
        if context then return context.bsp:PointContents(Vector(x, y, z)) end
        if not PointContents then
            return CONTENTS_EMPTY_L
        end

        pointVec.x, pointVec.y, pointVec.z = x, y, z
        return PointContents(pointVec) or CONTENTS_EMPTY_L
    end

    local function tr_fraction(tr)
        return tr and (tr.Fraction or tr.fraction) or 1
    end

    local function tr_hit(tr)
        return tr and (tr.Hit or tr.hit or tr_fraction(tr) < 1) or false
    end

    local function tr_startsolid(tr)
        return tr and (tr.StartSolid or tr.startsolid) or false
    end

    local function tr_allsolid(tr)
        return tr and (tr.AllSolid or tr.allsolid) or false
    end

    local function tr_hitpos(tr)
        return tr and (tr.HitPos or tr.hitpos or tr.endpos or tr.EndPos)
    end

    local function tr_normal(tr)
        return tr and (tr.HitNormal or tr.Normal or tr.normal)
    end

    local function tr_entity(tr)
        return tr and (tr.Entity or tr.HitEntity)
    end

    local function trace_is_ground(tr)
        if not tr or tr_startsolid(tr) or tr_allsolid(tr) then
            return false
        end

        local n = tr_normal(tr)
        return n and n.z >= GROUND_NORMAL and tr_hit(tr)
    end

    local function ground_entity_from_trace(tr)
        if not trace_is_ground(tr) then return NULL end

        local ent = tr_entity(tr)
        if IsValid(ent) then return ent end
        if ent and ent.IsWorld and ent:IsWorld() then return ent end

        -- Important: a world hit can still report Entity/HitEntity as NULL in some traces.
        -- If the trace itself is our authoritative walkable ground, mirror that to the
        -- engine as worldspawn instead of leaving the player with NULL ground.
        if game and game.GetWorld then
            local world = game.GetWorld()
            if IsValid(world) then return world end
        end

        return NULL
    end

    local function publish_ground_truth(ply, st, grounded, tr)
        grounded = grounded and trace_is_ground(tr) or false

        local ent = grounded and ground_entity_from_trace(tr) or NULL

        st.onground = grounded
        st.groundTrace = grounded and tr or nil
        st.groundEnt = ent
        st.engineGroundEnt = ent

        -- Do not cache-skip this call. The engine/default movement can clear or mutate the
        -- player ground entity outside this Lua state. Our movement state is the authority;
        -- ply:GetGroundEntity() is only an engine mirror for systems such as conveyors.
        if not context and ply.SetGroundEntity then
            ply:SetGroundEntity(ent)
        end

        return grounded, st.groundTrace, ent
    end

    local function clear_ground_truth(ply, st)
        return publish_ground_truth(ply, st, false, nil)
    end

    local function get_base_velocity(ply)
        if context then return 0, 0, 0 end
        if ply.GetBaseVelocity then
            local baseVelocity = ply:GetBaseVelocity()
            if baseVelocity then
                return baseVelocity.x or 0, baseVelocity.y or 0, baseVelocity.z or 0
            end
        end

        return 0, 0, 0
    end

    local function dot3(ax, ay, az, bx, by, bz)
        return ax * bx + ay * by + az * bz
    end

    local function normalize_2d(x, y)
        local len = sqrt(x * x + y * y)
        if len <= VELOCITY_EPSILON then
            return 0, 0, 0
        end

        local inv = 1 / len
        return x * inv, y * inv, len
    end

    local function normalize_3d(x, y, z)
        local len = sqrt(x * x + y * y + z * z)
        if len <= VELOCITY_EPSILON then
            return 0, 0, 0, 0
        end

        local inv = 1 / len
        return x * inv, y * inv, z * inv, len
    end

    local function angle_vectors(ang)
        local pitch = rad(ang.p)
        local yaw = rad(ang.y)

        local sp = sin(pitch)
        local cp = cos(pitch)
        local sy = sin(yaw)
        local cy = cos(yaw)

        return
            cp * cy, cp * sy, -sp,
            sy, -cy, 0,
            sp * cy, sp * sy, cp
    end

    local function yaw_wish(ang, fmove, smove)
        local yaw = rad(ang.y)
        local sy = sin(yaw)
        local cy = cos(yaw)

        local wishx = cy * fmove + sy * smove
        local wishy = sy * fmove - cy * smove

        return normalize_2d(wishx, wishy)
    end

    local function clip_velocity(vx, vy, vz, nx, ny, nz, overbounce)
        local backoff = dot3(vx, vy, vz, nx, ny, nz) * overbounce

        vx = vx - nx * backoff
        vy = vy - ny * backoff
        vz = vz - nz * backoff

        local adjust = dot3(vx, vy, vz, nx, ny, nz)
        if adjust < 0 then
            vx = vx - nx * adjust
            vy = vy - ny * adjust
            vz = vz - nz * adjust
        end

        return vx, vy, vz
    end

    local function cross3(ax, ay, az, bx, by, bz)
        return
            ay * bz - az * by,
            az * bx - ax * bz,
            ax * by - ay * bx
    end

    local function trace_surface_friction(tr)
        if not tr then return 1 end

        local friction = tr.SurfaceFriction or tr.surfaceFriction or 1
        friction = friction * 1.25

        if friction > 1 then friction = 1 end
        if friction <= 0 then friction = 1 end

        return friction
    end

    local function trace_is_ground(tr)
        if not tr or tr_startsolid(tr) or tr_allsolid(tr) then
            return false
        end

        local n = tr_normal(tr)
        return n and n.z >= GROUND_NORMAL and tr_hit(tr)
    end

    local function apply_ground_friction(vx, vy, dt, surfaceFriction, waterScale)
        local speed = sqrt(vx * vx + vy * vy)
        if speed <= 0.1 then
            return 0, 0
        end

        local friction = cvar_float(cvFriction, FRICTION_FALLBACK)
        local stopSpeed = cvar_float(cvStopSpeed, STOP_SPEED_FALLBACK)
        local control = speed < stopSpeed and stopSpeed or speed
        local drop = control * friction * (surfaceFriction or 1) * (waterScale or 1) * dt
        local newSpeed = speed - drop

        if newSpeed < 0 then
            newSpeed = 0
        end

        local scale = newSpeed / speed
        return vx * scale, vy * scale
    end

    local function apply_water_friction(vx, vy, vz, dt, surfaceFriction)
        local speed = sqrt(vx * vx + vy * vy + vz * vz)
        if speed <= 0.1 then
            return 0, 0, 0
        end

        local friction = cvar_float(cvFriction, FRICTION_FALLBACK)
        local drop = speed * friction * WATER_FRICTION_MUL * (surfaceFriction or 1) * dt
        local newSpeed = speed - drop

        if newSpeed < 0 then
            newSpeed = 0
        end

        local scale = newSpeed / speed
        return vx * scale, vy * scale, vz * scale
    end

    local function accelerate_2d(vx, vy, wishx, wishy, wishSpeed, accel, dt, surfaceFriction)
        local currentSpeed = vx * wishx + vy * wishy
        local addSpeed = wishSpeed - currentSpeed

        if addSpeed <= 0 then
            return vx, vy
        end

        local accelSpeed = accel * dt * wishSpeed * (surfaceFriction or 1)
        if accelSpeed > addSpeed then
            accelSpeed = addSpeed
        end

        return vx + accelSpeed * wishx, vy + accelSpeed * wishy
    end

    local function accelerate_3d(vx, vy, vz, wishx, wishy, wishz, wishSpeed, accel, dt, surfaceFriction)
        local currentSpeed = vx * wishx + vy * wishy + vz * wishz
        local addSpeed = wishSpeed - currentSpeed

        if addSpeed <= 0 then
            return vx, vy, vz
        end

        local accelSpeed = accel * dt * wishSpeed * (surfaceFriction or 1)
        if accelSpeed > addSpeed then
            accelSpeed = addSpeed
        end

        return vx + accelSpeed * wishx, vy + accelSpeed * wishy, vz + accelSpeed * wishz
    end

    local function air_accelerate(vx, vy, wishx, wishy, wishSpeed, dt, surfaceFriction)
        local wishSpd = wishSpeed
        if wishSpd > AIR_WISH_CAP then
            wishSpd = AIR_WISH_CAP
        end

        local currentSpeed = vx * wishx + vy * wishy
        local addSpeed = wishSpd - currentSpeed

        if addSpeed <= 0 then
            return vx, vy
        end

        local accel = (context and context.airAccelerate or cvar_float(cvAirAccelerate, AIR_ACCEL_FALLBACK))
        local accelSpeed = accel * dt * wishSpeed * (surfaceFriction or 1)
        if accelSpeed > addSpeed then
            accelSpeed = addSpeed
        end

        return vx + accelSpeed * wishx, vy + accelSpeed * wishy
    end

    local function clamp_velocity(vx, vy, vz)
        local maxVelocity = cvar_float(cvMaxVelocity, 3500)

        if vx > maxVelocity then vx = maxVelocity elseif vx < -maxVelocity then vx = -maxVelocity end
        if vy > maxVelocity then vy = maxVelocity elseif vy < -maxVelocity then vy = -maxVelocity end
        if vz > maxVelocity then vz = maxVelocity elseif vz < -maxVelocity then vz = -maxVelocity end

        if vx ~= vx then vx = 0 end
        if vy ~= vy then vy = 0 end
        if vz ~= vz then vz = 0 end

        return vx, vy, vz
    end

    local function entity_gravity(ply)
        if ply.GetGravity then
            local gravity = ply:GetGravity()
            if gravity and gravity ~= 0 then
                return gravity
            end
        end

        return 1
    end

    local function player_walk_speed(ply)
        if ply.GetWalkSpeed then
            local speed = ply:GetWalkSpeed()
            if speed and speed > 0 then return speed end
        end

        return WALK_SPEED_FALLBACK
    end

    local function player_run_speed(ply)
        if ply.GetRunSpeed then
            local speed = ply:GetRunSpeed()
            if speed and speed > 0 then return speed end
        end

        return SPRINT_SPEED_FALLBACK
    end

    local function player_jump_power(ply)
        if ply.GetJumpPower then
            local jumpPower = ply:GetJumpPower()
            if jumpPower and jumpPower > 0 then return jumpPower end
        end

        return 200
    end

    local function player_duck_speed_multiplier(ply)
        if ply.GetCrouchedWalkSpeed then
            local mul = ply:GetCrouchedWalkSpeed()
            if mul and mul > 0 then return mul end
        end

        return DUCK_SPEED_MUL_FALLBACK
    end

    local function probe_ground(ply, ox, oy, oz, mins, maxs, dist, out)
        local tr = trace_hull(
            ply,
            ox, oy, oz + SURFACE_EPSILON,
            ox, oy, oz - (dist or GROUND_SNAP),
            mins, maxs,
            MASK_PLAYERSOLID_L,
            out
        )

        if trace_is_ground(tr) then
            local hp = tr_hitpos(tr)
            if hp then
                return true, hp.x, hp.y, hp.z, trace_surface_friction(tr), tr
            end
        end

        return false, ox, oy, oz, 1, tr
    end

    local function slide_move(ply, ox, oy, oz, vx, vy, vz, dt, mins, maxs, out, ignoreWalkableGround)
        local timeLeft = dt
        local hitGround = false
        local hitNonWalkablePlane = false
        local hadZeroFractionWalkable = false
        local lastWalkableNx, lastWalkableNy, lastWalkableNz = 0, 0, 1
        local surfaceFriction = 1
        local lastTrace
        local numPlanes = 0
        local allFraction = 0

        local primalVx, primalVy, primalVz = vx, vy, vz
        local originalVx, originalVy, originalVz = vx, vy, vz

        for _ = 1, MAX_BUMPS do
            if abs(vx) <= VELOCITY_EPSILON and abs(vy) <= VELOCITY_EPSILON and abs(vz) <= VELOCITY_EPSILON then
                vx, vy, vz = 0, 0, 0
                break
            end

            local ex = ox + vx * timeLeft
            local ey = oy + vy * timeLeft
            local ez = oz + vz * timeLeft

            local tr = trace_hull(ply, ox, oy, oz, ex, ey, ez, mins, maxs, MASK_PLAYERSOLID_L, out)
            lastTrace = tr

            local fraction = tr_fraction(tr)
            local n = tr_normal(tr)

            if tr_allsolid(tr) then
                if n and n.z >= GROUND_NORMAL then
                    surfaceFriction = trace_surface_friction(tr)
                    hitGround = true
                    hadZeroFractionWalkable = true
                    lastWalkableNx, lastWalkableNy, lastWalkableNz = n.x, n.y, n.z

                    ox = ox + n.x * SURFACE_EPSILON
                    oy = oy + n.y * SURFACE_EPSILON
                    oz = oz + n.z * SURFACE_EPSILON

                    vx, vy, vz = clip_velocity(vx, vy, vz, n.x, n.y, n.z, OVERBOUNCE)
                    if vz < 0 then vz = 0 end

                    return ox, oy, oz, vx, vy, vz, true, surfaceFriction, tr
                end

                return ox, oy, oz, 0, 0, 0, false, surfaceFriction, tr
            end

            allFraction = allFraction + fraction

            if fraction > 0 then
                local hp = tr_hitpos(tr)
                if hp then
                    ox, oy, oz = hp.x, hp.y, hp.z
                end

                originalVx, originalVy, originalVz = vx, vy, vz
                numPlanes = 0
            end

            if not tr_hit(tr) or fraction >= 1 then
                break
            end

            if not n then
                vx, vy, vz = 0, 0, 0
                break
            end

            local walkablePlane = n.z >= GROUND_NORMAL
            local ignoreAsGround = ignoreWalkableGround and primalVz > 0 and walkablePlane
            local zeroFractionTouch = fraction <= ZERO_FRACTION_EPSILON

            if walkablePlane then
                surfaceFriction = trace_surface_friction(tr)

                if not ignoreAsGround then
                    hitGround = true
                end

                lastWalkableNx, lastWalkableNy, lastWalkableNz = n.x, n.y, n.z

                if zeroFractionTouch then
                    hadZeroFractionWalkable = true

                    ox = ox + n.x * SURFACE_EPSILON
                    oy = oy + n.y * SURFACE_EPSILON
                    oz = oz + n.z * SURFACE_EPSILON

                    allFraction = allFraction + ZERO_FRACTION_EPSILON
                end
            else
                hitNonWalkablePlane = true
            end

            timeLeft = timeLeft * (1 - fraction)
            if timeLeft <= 0 then
                break
            end

            if numPlanes >= MAX_CLIP_PLANES then
                vx, vy, vz = 0, 0, 0
                break
            end

            numPlanes = numPlanes + 1
            planeNx[numPlanes] = n.x
            planeNy[numPlanes] = n.y
            planeNz[numPlanes] = n.z

            local foundPlane = false

            for i = 1, numPlanes do
                local newVx, newVy, newVz = clip_velocity(
                    originalVx, originalVy, originalVz,
                    planeNx[i], planeNy[i], planeNz[i],
                    OVERBOUNCE
                )

                if ignoreWalkableGround
                    and primalVz > 0
                    and planeNz[i] >= GROUND_NORMAL
                    and newVz < originalVz then
                    newVz = originalVz
                end

                local ok = true
                for j = 1, numPlanes do
                    if j ~= i and dot3(newVx, newVy, newVz, planeNx[j], planeNy[j], planeNz[j]) < -VELOCITY_EPSILON then
                        ok = false
                        break
                    end
                end

                if ok then
                    vx, vy, vz = newVx, newVy, newVz
                    foundPlane = true
                    break
                end
            end

            if not foundPlane then
                if numPlanes == 2 then
                    local dirX, dirY, dirZ = cross3(
                        planeNx[1], planeNy[1], planeNz[1],
                        planeNx[2], planeNy[2], planeNz[2]
                    )

                    dirX, dirY, dirZ = normalize_3d(dirX, dirY, dirZ)
                    local dot = dot3(dirX, dirY, dirZ, vx, vy, vz)
                    vx, vy, vz = dirX * dot, dirY * dot, dirZ * dot
                else
                    vx, vy, vz = 0, 0, 0
                    break
                end
            end

            if dot3(vx, vy, vz, primalVx, primalVy, primalVz) <= 0 then
                if hadZeroFractionWalkable and not hitNonWalkablePlane then
                    break
                end

                vx, vy, vz = 0, 0, 0
                break
            end
        end

        if allFraction == 0 then
            if hitGround and not hitNonWalkablePlane then
                if vz < 0 then
                    vz = 0
                end

                if hadZeroFractionWalkable then
                    ox = ox + lastWalkableNx * SURFACE_EPSILON
                    oy = oy + lastWalkableNy * SURFACE_EPSILON
                    oz = oz + lastWalkableNz * SURFACE_EPSILON
                end
            else
                vx, vy, vz = 0, 0, 0
            end
        end

        return ox, oy, oz, vx, vy, vz, hitGround, surfaceFriction, lastTrace
    end

    local function step_slide_move(ply, ox, oy, oz, vx, vy, vz, dt, mins, maxs, st)
        local startX, startY, startZ = ox, oy, oz
        local startVx, startVy, startVz = vx, vy, vz

        local downOx, downOy, downOz, downVx, downVy, downVz, downGround, downFriction, downTrace =
            slide_move(ply, ox, oy, oz, vx, vy, vz, dt, mins, maxs, st.traceMove, false)

        local upTr = trace_hull(
            ply,
            startX, startY, startZ,
            startX, startY, startZ + STEP_HEIGHT,
            mins, maxs,
            MASK_PLAYERSOLID_L,
            st.traceStepUp
        )

        if tr_startsolid(upTr) or tr_allsolid(upTr) or tr_fraction(upTr) < 1 then
            return downOx, downOy, downOz, downVx, downVy, downVz, downGround, downFriction, downTrace
        end

        local upX, upY, upZ = startX, startY, startZ + STEP_HEIGHT

        local stepOx, stepOy, stepOz, stepVx, stepVy, stepVz =
            slide_move(ply, upX, upY, upZ, startVx, startVy, startVz, dt, mins, maxs, st.traceStepMove, false)

        local downTr = trace_hull(
            ply,
            stepOx, stepOy, stepOz,
            stepOx, stepOy, stepOz - STEP_HEIGHT - STEP_DOWN - SURFACE_EPSILON,
            mins, maxs,
            MASK_PLAYERSOLID_L,
            st.traceStepDown
        )

        if not trace_is_ground(downTr) then
            return downOx, downOy, downOz, downVx, downVy, downVz, downGround, downFriction, downTrace
        end

        local hp = tr_hitpos(downTr)
        if hp then
            stepOx, stepOy, stepOz = hp.x, hp.y, hp.z + SURFACE_EPSILON
        end

        local downDist = (downOx - startX) * (downOx - startX) + (downOy - startY) * (downOy - startY)
        local stepDist = (stepOx - startX) * (stepOx - startX) + (stepOy - startY) * (stepOy - startY)

        if stepDist > downDist then
            if stepVz < 0 then stepVz = 0 end
            return stepOx, stepOy, stepOz, stepVx, stepVy, stepVz, true, trace_surface_friction(downTr), downTr
        end

        return downOx, downOy, downOz, downVx, downVy, downVz, downGround, downFriction, downTrace
    end

    local function cheap_water_level(ply, ox, oy, oz, mins, maxs)
        local feetZ = oz + mins.z + 1
        local waistZ = oz + (mins.z + maxs.z) * 0.5
        local eyesZ = oz + (maxs.z - 8)

        local contents = point_contents(ox, oy, feetZ)
        if band(contents, MASK_WATER_L) == 0 then
            return 0, CONTENTS_EMPTY_L
        end

        local waterType = contents
        local level = 1

        contents = point_contents(ox, oy, waistZ)
        if band(contents, MASK_WATER_L) ~= 0 then
            waterType = contents
            level = 2

            contents = point_contents(ox, oy, eyesZ)
            if band(contents, MASK_WATER_L) ~= 0 then
                waterType = contents
                level = 3
            end
        end

        return level, waterType
    end

    local function water_move(ply, mv, ox, oy, oz, vx, vy, vz, dt, mins, maxs, buttons, ducking, waterType, st, umove,
                              bvx, bvy, bvz)
        local ang = mv:GetAngles()
        local fmove = mv:GetForwardSpeed()
        local smove = mv:GetSideSpeed()
        umove = umove or 0

        local fx, fy, fz, rx, ry, rz = angle_vectors(ang)

        local wishx = fx * fmove + rx * smove
        local wishy = fy * fmove + ry * smove
        local wishz = fz * fmove + rz * smove + umove

        if band(buttons, BTN_JUMP) ~= 0 then
            if band(waterType or 0, CONTENTS_SLIME_L) ~= 0 then
                wishz = wishz + WATER_JUMP_SPEED * 0.8
            else
                wishz = wishz + WATER_JUMP_SPEED
            end
        elseif ducking then
            wishz = wishz - WATER_JUMP_SPEED
        elseif fmove == 0 and smove == 0 and umove == 0 then
            wishz = wishz - WATER_SINK_SPEED
        end

        local wishSpeed
        wishx, wishy, wishz, wishSpeed = normalize_3d(wishx, wishy, wishz)

        local maxSpeed = mv:GetMaxSpeed()
        if maxSpeed <= 0 then maxSpeed = player_walk_speed(ply) end
        maxSpeed = maxSpeed * 0.8

        if wishSpeed > maxSpeed then
            wishSpeed = maxSpeed
        end

        vx, vy, vz = apply_water_friction(vx, vy, vz, dt, 1)

        if wishSpeed > 0 then
            vx, vy, vz = accelerate_3d(vx, vy, vz, wishx, wishy, wishz, wishSpeed, WATER_ACCEL, dt, 1)
        else
            local gravity = cvar_float(cvGravity, GRAVITY_FALLBACK) * entity_gravity(ply)
            vz = vz - gravity * WATER_GRAVITY_MUL * dt
        end

        vx, vy, vz = clamp_velocity(vx, vy, vz)

        local moveVx = vx + bvx
        local moveVy = vy + bvy
        local moveVz = vz + bvz

        ox, oy, oz, moveVx, moveVy, moveVz =
            slide_move(ply, ox, oy, oz, moveVx, moveVy, moveVz, dt, mins, maxs, st.traceWater, false)

        vx = moveVx - bvx
        vy = moveVy - bvy
        vz = moveVz - bvz

        return ox, oy, oz, vx, vy, vz
    end

    local function is_ladder_trace(tr)
        if not tr then return false end

        local contents = tr.Contents or tr.contents or 0
        if band(contents, CONTENTS_LADDER_L) ~= 0 then
            return true
        end

        local surfaceData = tr.SurfaceData or tr.surfaceData
        if istable and istable(surfaceData) and surfaceData.game and surfaceData.game.climbable ~= 0 then
            return true
        end

        return false
    end

    local function find_ladder(ply, ox, oy, oz, mins, maxs, ang, fmove, smove, oldNx, oldNy, oldNz, st)
        local fx, fy, fz, rx, ry, rz = angle_vectors(ang)
        local wishx, wishy, wishz

        if fmove ~= 0 or smove ~= 0 then
            wishx = fx * fmove + rx * smove
            wishy = fy * fmove + ry * smove
            wishz = fz * fmove + rz * smove
            wishx, wishy, wishz = normalize_3d(wishx, wishy, wishz)
        elseif oldNx then
            wishx, wishy, wishz = -oldNx, -oldNy, -oldNz
        else
            wishx, wishy, wishz = fx, fy, fz
        end

        local tr = trace_hull(
            ply,
            ox, oy, oz,
            ox + wishx * LADDER_CHECK_DIST,
            oy + wishy * LADDER_CHECK_DIST,
            oz + wishz * LADDER_CHECK_DIST,
            mins, maxs,
            LADDER_MASK_L,
            st.traceLadder
        )

        if is_ladder_trace(tr) then
            local n = tr_normal(tr)
            if n then
                return true, n.x, n.y, n.z
            end

            return true, -wishx, -wishy, 0
        end

        local contents = point_contents(ox, oy, oz + 36)
        if band(contents, CONTENTS_LADDER_L) ~= 0 then
            if oldNx then
                return true, oldNx, oldNy, oldNz
            end

            return true, -fx, -fy, 0
        end

        return false
    end

    local function clear_ladder_state(st)
        st.onladder = false
        st.ladderNx = 0
        st.ladderNy = 0
        st.ladderNz = 0
    end

    local function ladder_move(ply, mv, st, ox, oy, oz, vx, vy, vz, dt, mins, maxs, buttons, bvx, bvy, bvz)
        local ang = mv:GetAngles()
        local fmove = mv:GetForwardSpeed()
        local smove = mv:GetSideSpeed()

        local found, nx, ny, nz = find_ladder(
            ply, ox, oy, oz, mins, maxs, ang, fmove, smove,
            st.ladderNx, st.ladderNy, st.ladderNz, st
        )

        if not found then
            clear_ladder_state(st)
            return false, ox, oy, oz, vx, vy, vz
        end

        st.onladder = true
        st.ladderNx, st.ladderNy, st.ladderNz = nx, ny, nz
        st.onground = false

        if band(buttons, BTN_JUMP) ~= 0 then
            clear_ladder_state(st)

            vx = nx * LADDER_DISMOUNT
            vy = ny * LADDER_DISMOUNT
            vz = max(nz * LADDER_DISMOUNT, player_jump_power(ply) * 0.5)

            local moveVx = vx + bvx
            local moveVy = vy + bvy
            local moveVz = vz + bvz

            ox, oy, oz, moveVx, moveVy, moveVz =
                slide_move(ply, ox, oy, oz, moveVx, moveVy, moveVz, dt, mins, maxs, st.traceLadderMove, true)

            vx = moveVx - bvx
            vy = moveVy - bvy
            vz = moveVz - bvz

            return true, ox, oy, oz, vx, vy, vz
        end

        local forwardSpeed = 0
        local sideSpeed = 0

        if band(buttons, BTN_FORWARD) ~= 0 then forwardSpeed = forwardSpeed + LADDER_SPEED end
        if band(buttons, BTN_BACK) ~= 0 then forwardSpeed = forwardSpeed - LADDER_SPEED end
        if band(buttons, BTN_MOVERIGHT) ~= 0 then sideSpeed = sideSpeed + LADDER_SPEED end
        if band(buttons, BTN_MOVELEFT) ~= 0 then sideSpeed = sideSpeed - LADDER_SPEED end

        if forwardSpeed == 0 and sideSpeed == 0 then
            return true, ox, oy, oz, 0, 0, 0
        end

        local fx, fy, fz, rx, ry, rz = angle_vectors(ang)

        local ladderVx = fx * forwardSpeed + rx * sideSpeed
        local ladderVy = fy * forwardSpeed + ry * sideSpeed
        local ladderVz = fz * forwardSpeed + rz * sideSpeed

        local upX, upY, upZ = 0, 0, 1
        local perpX, perpY, perpZ = cross3(upX, upY, upZ, nx, ny, nz)
        perpX, perpY, perpZ = normalize_3d(perpX, perpY, perpZ)

        local normalDot = dot3(ladderVx, ladderVy, ladderVz, nx, ny, nz)
        local lateralX = ladderVx - nx * normalDot
        local lateralY = ladderVy - ny * normalDot
        local lateralZ = ladderVz - nz * normalDot

        local climbX, climbY, climbZ = cross3(nx, ny, nz, perpX, perpY, perpZ)

        vx = lateralX - normalDot * climbX
        vy = lateralY - normalDot * climbY
        vz = lateralZ - normalDot * climbZ

        local len
        vx, vy, vz, len = normalize_3d(vx, vy, vz)
        if len > 0 then
            vx, vy, vz = vx * LADDER_SPEED, vy * LADDER_SPEED, vz * LADDER_SPEED
        end

        local moveVx = vx + bvx
        local moveVy = vy + bvy
        local moveVz = vz + bvz

        ox, oy, oz, moveVx, moveVy, moveVz =
            slide_move(ply, ox, oy, oz, moveVx, moveVy, moveVz, dt, mins, maxs, st.traceLadderMove, false)

        vx = moveVx - bvx
        vy = moveVy - bvy
        vz = moveVz - bvz

        return true, ox, oy, oz, vx, vy, vz
    end

    local function noclip_move(ply, mv, dt)
        local buttons = mv:GetButtons()
        local speed = player_run_speed(ply) * cvar_float(cvNoclipSpeed, 5)
        if band(buttons, BTN_SPEED) ~= 0 then speed = speed * 2 end
        if band(buttons, BTN_DUCK) ~= 0 then speed = speed * 0.5 end
        local fx, fy, fz, rx, ry, rz = angle_vectors(mv:GetAngles())
        local forward, side, up = mv:GetForwardSpeed(), mv:GetSideSpeed(), mv:GetUpSpeed()
        if band(buttons, BTN_JUMP) ~= 0 then up = up + player_run_speed(ply) end
        local wx, wy, wz, wishSpeed = normalize_3d(fx * forward + rx * side, fy * forward + ry * side, fz * forward + rz * side + up)
        wishSpeed = min(wishSpeed / max(player_run_speed(ply), 1), 1) * speed
        local vel = mv:GetVelocity()
        local length = sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
        local friction = length > 0 and max(0, length - max(length, speed * 0.25) * 4 * dt) / length or 0
        local vx, vy, vz = vel.x * friction, vel.y * friction, vel.z * friction
        vx, vy, vz = accelerate_3d(vx, vy, vz, wx, wy, wz, wishSpeed, cvar_float(cvNoclipAccelerate, 5), dt, 1)
        local origin = mv:GetOrigin()
        origin.x, origin.y, origin.z = origin.x + vx * dt, origin.y + vy * dt, origin.z + vz * dt
        vel.x, vel.y, vel.z = vx, vy, vz
        mv:SetOrigin(origin)
        mv:SetVelocity(vel)
    end

    -- Called with movement data in BSP coordinates by the miniature walk session.
    function PocketMap.Movement.Step(ply, mv, session)
        context = session
        if CLIENT and ply ~= LocalPlayer() then return end
        if not IsValid(ply) or not ply:Alive() then return end
        if ply.InVehicle and ply:InVehicle() then return end

        local moveType = session.noclip and MT_NOCLIP or MT_WALK
        if moveType ~= MT_WALK and moveType ~= MT_LADDER and moveType ~= MT_NOCLIP then
            return
        end

        local dt = TickInterval()
        if not dt or dt <= 0 then return true end

        if ply.GetLaggedMovementValue then
            local laggedMovement = ply:GetLaggedMovementValue()
            if laggedMovement then
                dt = dt * laggedMovement
                if dt <= 0 then return true end
            end
        end

        if session.noclip then
            states[session] = nil
            noclip_move(ply, mv, dt)
            return true
        end

        local st = states[session]
        if not st then
            st = {
                onground = false,
                ducking = false,
                wasJump = false,
                surfaceFriction = 1,
                onladder = false,
                ladderNx = 0,
                ladderNy = 0,
                ladderNz = 0,
                groundTicks = 0,
                airTicks = 0,
                moveCounter = 0,
                lastLandMove = -1,
                lastJumpMove = -1,
                groundTrace = nil,
                groundEnt = NULL,
                engineGroundEnt = NULL,
                traceGround = {},
                traceMove = {},
                traceStepUp = {},
                traceStepMove = {},
                traceStepDown = {},
                traceSnap = {},
                traceWater = {},
                traceLadder = {},
                traceLadderMove = {},
                traceDuck = {}
            }
            states[session] = st
        end

        st.moveCounter = (st.moveCounter or 0) + 1

        local wasGround = st.onground or false

        if moveType ~= MT_LADDER and not st.onladder then
            st.ladderNx = 0
            st.ladderNy = 0
            st.ladderNz = 0
        end

        local buttons = mv:GetButtons()
        local fmove = mv:GetForwardSpeed()
        local smove = mv:GetSideSpeed()
        local umove = mv:GetUpSpeed()

        local flags = ply.GetFlags and ply:GetFlags() or 0
        if band(flags, FL_FROZEN_L) ~= 0 or band(flags, FL_ONTRAIN_L) ~= 0 then
            fmove = 0
            smove = 0
            umove = 0
            mv:SetForwardSpeed(0)
            mv:SetSideSpeed(0)
            mv:SetUpSpeed(0)
        end

        local vel = mv:GetVelocity()
        local origin = mv:GetOrigin()

        local vx, vy, vz = vel.x, vel.y, vel.z
        local ox, oy, oz = origin.x, origin.y, origin.z

        local bvx, bvy, bvz = get_base_velocity(ply)

        local wantDuck = band(buttons, BTN_DUCK) ~= 0
        local engineCrouching = false
        local ducking = wantDuck or engineCrouching or st.ducking

        if st.ducking and not wantDuck and not engineCrouching then
            local standTr = trace_hull(
                ply,
                ox, oy, oz,
                ox, oy, oz,
                STAND_MINS,
                STAND_MAXS,
                MASK_PLAYERSOLID_L,
                st.traceDuck
            )

            ducking = tr_startsolid(standTr) or tr_allsolid(standTr) or tr_hit(standTr)
        end

        st.ducking = ducking
        local mins, maxs = hull_for_duck(ducking)

        local sprinting = band(buttons, BTN_SPEED) ~= 0 and not ducking and fmove > 0
        local maxSpeed = sprinting and player_run_speed(ply) or player_walk_speed(ply)

        if ply.GetPlayerMaxSpeed then
            local playerMaxSpeed = ply:GetPlayerMaxSpeed()
            if playerMaxSpeed and playerMaxSpeed > 0 then
                maxSpeed = playerMaxSpeed
            end
        end

        if ducking then
            maxSpeed = maxSpeed * player_duck_speed_multiplier(ply)
        end

        local engineMax = mv:GetMaxSpeed()
        if engineMax and engineMax > 0 and engineMax < maxSpeed then
            maxSpeed = engineMax
        end

        if mv.GetMaxClientSpeed then
            local clientMax = mv:GetMaxClientSpeed()
            if clientMax and clientMax > 0 and clientMax < maxSpeed then
                maxSpeed = clientMax
            end
        end

        mv:SetMaxSpeed(maxSpeed)

        local waterLevel, waterType = 0, CONTENTS_EMPTY_L
        if moveType ~= MT_NOCLIP then
            waterLevel, waterType = cheap_water_level(ply, ox, oy, oz, mins, maxs)
        end

        if moveType ~= MT_NOCLIP then
            if moveType == MT_LADDER or st.onladder then
                local handled
                handled, ox, oy, oz, vx, vy, vz =
                    ladder_move(ply, mv, st, ox, oy, oz, vx, vy, vz, dt, mins, maxs, buttons, bvx, bvy, bvz)

                if handled then
                    clear_ground_truth(ply, st)
                    st.airTicks = (st.airTicks or 0) + 1
                    st.groundTicks = 0

                    origin.x, origin.y, origin.z = ox, oy, oz
                    vel.x, vel.y, vel.z = clamp_velocity(vx, vy, vz)
                    mv:SetOrigin(origin)
                    mv:SetVelocity(vel)
                    return true
                end
            elseif fmove ~= 0 or smove ~= 0 then
                local foundLadder = find_ladder(
                    ply,
                    ox, oy, oz,
                    mins, maxs,
                    mv:GetAngles(),
                    fmove,
                    smove,
                    nil, nil, nil,
                    st
                )

                if foundLadder then
                    local handled
                    handled, ox, oy, oz, vx, vy, vz =
                        ladder_move(ply, mv, st, ox, oy, oz, vx, vy, vz, dt, mins, maxs, buttons, bvx, bvy, bvz)

                    if handled then
                        clear_ground_truth(ply, st)
                        st.airTicks = (st.airTicks or 0) + 1
                        st.groundTicks = 0

                        origin.x, origin.y, origin.z = ox, oy, oz
                        vel.x, vel.y, vel.z = clamp_velocity(vx, vy, vz)
                        mv:SetOrigin(origin)
                        mv:SetVelocity(vel)
                        return true
                    end
                end
            end
        else
            clear_ladder_state(st)
        end

        if waterLevel >= 2 then
            clear_ground_truth(ply, st)

            ox, oy, oz, vx, vy, vz = water_move(
                ply,
                mv,
                ox, oy, oz,
                vx, vy, vz,
                dt,
                mins,
                maxs,
                buttons,
                ducking,
                waterType,
                st,
                umove,
                bvx, bvy, bvz
            )

            st.airTicks = (st.airTicks or 0) + 1
            st.groundTicks = 0

            origin.x, origin.y, origin.z = ox, oy, oz
            vel.x, vel.y, vel.z = clamp_velocity(vx, vy, vz)
            mv:SetOrigin(origin)
            mv:SetVelocity(vel)
            return true
        end

        local onground = false
        local groundTrace = nil
        local surfaceFriction = st.surfaceFriction or 1

        if vz <= NON_JUMP_VELOCITY then
            -- One-truth ground state: the pre-jump ground probe must be allowed to recover
            -- the same groundedness that the later snap/down-step path would recover anyway.
            -- Otherwise walking/friction can feel grounded while the jump gate saw airborne.
            local preJumpGroundDist = GROUND_SNAP
            if waterLevel == 0 and wasGround and vz <= 0 then
                preJumpGroundDist = STEP_DOWN
            end

            local g, gx, gy, gz, gf, gtr = probe_ground(ply, ox, oy, oz, mins, maxs, preJumpGroundDist, st.traceGround)
            if g then
                ox, oy, oz = gx, gy, gz + SURFACE_EPSILON
                onground = true
                surfaceFriction = gf
                groundTrace = gtr
                if vz < 0 then vz = 0 end
            end
        end

        -- Publish the current movement ground state before basevelocity is read.
        -- This is the single authoritative ground state for jump/friction/basevelocity.
        if onground and trace_is_ground(groundTrace) then
            onground, groundTrace = publish_ground_truth(ply, st, true, groundTrace)
            bvx, bvy, bvz = get_base_velocity(ply)
        else
            onground, groundTrace = clear_ground_truth(ply, st)
        end

        local justLandedPreMove = onground and not wasGround
        if justLandedPreMove then
            st.lastLandMove = st.moveCounter
        end

        local jumpHeld = band(buttons, BTN_JUMP) ~= 0
        local wantsJump = jumpHeld and (AUTO_BHOP or not st.wasJump)
        st.wasJump = jumpHeld

        local jumped = false
        if onground and wantsJump then
            clear_ground_truth(ply, st)

            vz = player_jump_power(ply)
            onground = false
            groundTrace = nil
            jumped = true

            st.lastJumpMove = st.moveCounter
        end

        local wishx, wishy, wishSpeed = yaw_wish(mv:GetAngles(), fmove, smove)
        if wishSpeed > maxSpeed then
            wishSpeed = maxSpeed
        end

        if onground and not jumped then
            if vz < 0 then vz = 0 end

            local waterScale = waterLevel > 0 and WATER_FRICTION_MUL or 1
            local skipFriction = AUTO_BHOP and jumpHeld and justLandedPreMove

            if not skipFriction then
                vx, vy = apply_ground_friction(vx, vy, dt, surfaceFriction, waterScale)
            end

            if wishSpeed > 0 then
                vx, vy = accelerate_2d(
                    vx, vy,
                    wishx, wishy,
                    wishSpeed,
                    cvar_float(cvAccelerate, ACCEL_FALLBACK),
                    dt,
                    surfaceFriction
                )
            end

            vz = 0

            local moveVx = vx + bvx
            local moveVy = vy + bvy
            local moveVz = vz + bvz

            if moveVx ~= 0 or moveVy ~= 0 or moveVz ~= 0 then
                ox, oy, oz, moveVx, moveVy, moveVz, onground, surfaceFriction, groundTrace =
                    step_slide_move(ply, ox, oy, oz, moveVx, moveVy, moveVz, dt, mins, maxs, st)

                vx = moveVx - bvx
                vy = moveVy - bvy
                vz = moveVz - bvz
            end
        else
            local gravity = cvar_float(cvGravity, GRAVITY_FALLBACK) * entity_gravity(ply)
            local gravityScale = waterLevel > 0 and WATER_GRAVITY_MUL or 1

            vz = vz - gravity * gravityScale * dt * 0.5

            if wishSpeed > 0 then
                vx, vy = air_accelerate(vx, vy, wishx, wishy, wishSpeed, dt, surfaceFriction)
            end

            vx, vy, vz = clamp_velocity(vx, vy, vz)

            local moveVx = vx + bvx
            local moveVy = vy + bvy
            local moveVz = vz + bvz

            local ignoreWalkableGround = jumped

            ox, oy, oz, moveVx, moveVy, moveVz, onground, surfaceFriction, groundTrace =
                slide_move(ply, ox, oy, oz, moveVx, moveVy, moveVz, dt, mins, maxs, st.traceMove, ignoreWalkableGround)

            vx = moveVx - bvx
            vy = moveVy - bvy
            vz = moveVz - bvz

            if jumped then
                onground = false
                groundTrace = nil
            elseif onground and vz > NON_JUMP_VELOCITY then
                onground = false
                groundTrace = nil
            elseif onground and vz < 0 then
                vz = 0
            end

            if not onground then
                vz = vz - gravity * gravityScale * dt * 0.5
            elseif vz < 0 then
                vz = 0
            end
        end

        if not jumped and waterLevel == 0 and vz <= 0 and (onground or st.onground) then
            local snapDist = st.onground and (STEP_HEIGHT + STEP_DOWN) or STEP_DOWN
            local g, gx, gy, gz, gf, snapTrace = probe_ground(ply, ox, oy, oz, mins, maxs, snapDist, st.traceSnap)

            if g then
                ox, oy, oz = gx, gy, gz + SURFACE_EPSILON
                onground = true
                surfaceFriction = gf
                groundTrace = snapTrace
                if vz < 0 then vz = 0 end
            else
                onground = false
                groundTrace = nil
            end
        end

        if onground and not wasGround then
            st.lastLandMove = st.moveCounter
        end

        if jumped then
            st.lastJumpMove = st.moveCounter
        end

        if onground then
            st.groundTicks = (wasGround and (st.groundTicks or 0) or 0) + 1
            st.airTicks = 0
        else
            st.airTicks = ((not wasGround) and (st.airTicks or 0) or 0) + 1
            st.groundTicks = 0
        end

        st.surfaceFriction = surfaceFriction or 1

        -- Final publication of the same authoritative ground state. This is intentionally
        -- not a new trace; it only mirrors the final Lua movement state to the player entity.
        if onground and trace_is_ground(groundTrace) then
            onground, groundTrace = publish_ground_truth(ply, st, true, groundTrace)
        else
            onground, groundTrace = clear_ground_truth(ply, st)
        end

        origin.x, origin.y, origin.z = ox, oy, oz
        vel.x, vel.y, vel.z = clamp_velocity(vx, vy, vz)

        mv:SetOrigin(origin)
        mv:SetVelocity(vel)

        return true
    end
end
