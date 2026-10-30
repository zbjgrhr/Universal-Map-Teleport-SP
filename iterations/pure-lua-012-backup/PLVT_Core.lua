-- Experimental SP vehicle travel through overlapping loaded areas.
-- Uses only vanilla Lua APIs. No Java bridge, ID changes, remove/add or cloning.
local P = {session=nil, status="", progress=0}
local PREFIX = "[PureLuaVehicleTest] "
local MAX_STEP, STREAM_TIMEOUT, TRIP_TIMEOUT = 24, 20000, 600000

local function finite(n) return type(n)=="number" and n==n and math.abs(n)<10000000 end
local function now() return getTimestampMs() end
local function distance(x,y,a,b) return math.sqrt((x-a)^2+(y-b)^2) end
local function log(s) print(PREFIX .. s) end
local function say(player,s) if player then player:Say("[Lua Test] " .. s) end end
local function registered(s)
    return not s.vehicle:isRemovedFromWorld() and
        s.vehicle:getId()==s.id and s.vehicle:getSqlId()==s.sqlId and
        getVehicleById(s.id)==s.vehicle and
        getCell():getVehicles():contains(s.vehicle)
end

local function ground(x,y)
    local square=getCell():getGridSquare(math.floor(x),math.floor(y),0)
    if not square or not square:getFloor() or not square:isFree(false) then return nil end
    local sprite=square:getFloor():getSprite()
    if not sprite or sprite:getProperties():has(IsoFlagType.water) then return nil end
    return square
end

local function clear(s,x,y)
    -- Require a complete surrounding area before touching the physical body.
    for dx=-8,8,8 do for dy=-8,8,8 do
        if not getCell():getGridSquare(math.floor(x+dx),math.floor(y+dy),0) then return nil end
    end end
    local r=s.bound
    for tx=math.floor(x)-r,math.floor(x)+r do
        for ty=math.floor(y)-r,math.floor(y)+r do
            local dx,dy=tx+0.5-x,ty+0.5-y
            if math.abs(dx*s.ux+dy*s.uy)<=s.halfX+0.71 and
                math.abs(dx*s.vx+dy*s.vy)<=s.halfZ+0.71 and not ground(tx,ty) then return nil end
        end
    end
    local iterator=getCell():getVehicles():iterator()
    while iterator:hasNext() do
        local other=iterator:next()
        if other~=s.vehicle then
            local extents=other:getScript() and other:getScript():getExtents()
            local radius=extents and math.sqrt(extents:x()^2+extents:z()^2)/2 or 5
            if distance(x,y,other:getX(),other:getY()) < s.radius+radius+0.75 then return nil end
        end
    end
    return ground(x,y)
end

local function geometry(vehicle)
    local ext=assert(vehicle:getScript():getExtents(),"Vehicle size is unavailable")
    local o=vehicle:getWorldPos(0,0,0,Vector3f.new())
    local a=vehicle:getWorldPos(1,0,0,Vector3f.new())
    local b=vehicle:getWorldPos(0,0,1,Vector3f.new())
    local ux,uy,vx,vy=a:x()-o:x(),a:y()-o:y(),b:x()-o:x(),b:y()-o:y()
    local u,v=math.sqrt(ux*ux+uy*uy),math.sqrt(vx*vx+vy*vy)
    assert(u>0.01 and v>0.01,"Vehicle orientation is unavailable")
    local hx,hz=ext:x()/2+0.35,ext:z()/2+0.35
    assert(hx>0 and hz>0 and hx<=10 and hz<=12,"Vehicle is too large for this experiment")
    return {halfX=hx,halfZ=hz,ux=ux/u,uy=uy/u,vx=vx/v,vy=vy/v,
        radius=math.sqrt(hx*hx+hz*hz),bound=math.ceil(math.sqrt(hx*hx+hz*hz))+1}
end

local function place(s,x,y,square)
    assert(registered(s),"Vehicle is no longer registered; stopped without recreating it")
    assert(square and clear(s,x,y),"Step destination is no longer clear or loaded")
    local vehicle=s.vehicle
    local transform=Transform.new()
    vehicle:getWorldTransform(transform)
    local origin=transform:getOrigin()
    local physicalPosition=vehicle:getWorldPos(0,0,0,Vector3f.new())
    -- Physics axes are X/height/Y. Relative translation avoids accessing the
    -- unexposed WorldSimulation singleton or hard-coding its world offsets.
    origin:set(origin:x()+x-physicalPosition:x(),origin:y(),origin:z()+y-physicalPosition:y())
    vehicle:setPhysicsActive(false,true)
    vehicle:setWorldTransform(transform)
    vehicle:setX(x);vehicle:setY(y);vehicle:setZ(0)
    vehicle:setCurrent(square)
    -- Commit the normal native chunk-list transition BEFORE moving the camera.
    -- Both old and new chunks are still in the player's loaded area here.
    vehicle:update()
    assert(registered(s),"Vehicle registration changed during the step")
    assert(distance(vehicle:getX(),vehicle:getY(),x,y)<1.5,"Physics rejected the vehicle step")
    assert(vehicle:getSquare() and vehicle:getSquare():getChunk()==square:getChunk(),
        "Vehicle has not joined the destination chunk")
    return transform
end

local function followSeat(s)
    assert(s.player:getVehicle()==s.vehicle,"Player left the seat; transfer stopped")
    local position=s.vehicle:getPassengerWorldPos(s.seat,Vector3f.new())
    assert(position,"Seat position unavailable")
    -- teleportTo() forcibly exits vehicles. Keep the seat throughout transit.
    s.player:setX(position:x());s.player:setY(position:y());s.player:setZ(0)
    s.player:setLastX(position:x());s.player:setLastY(position:y())
    local square=getCell():getGridSquare(math.floor(position:x()),math.floor(position:y()),0)
    assert(square,"The player seat is outside loaded ground")
    s.player:setCurrent(square)
end

local function persist(s)
    if not registered(s) or s.player:getVehicle()~=s.vehicle then return end
    -- Native exit/enter updates VehiclesDB2. No raw DB access or serialization.
    if s.vehicle:exit(s.player) then
        local entered=s.vehicle:enter(s.seat,s.player)
        if entered then s.vehicle:setCharacterPosition(s.player,s.seat,"inside") end
        log("native save checkpoint: sqlId=" .. s.sqlId .. " seated=" .. tostring(entered))
    end
end

function P.stop(message,success)
    local s=P.session
    P.session=nil
    P.status=message or "Cancelled at the current loaded checkpoint"
    if s then
        if registered(s) then
            local ok,why=pcall(persist,s)
            if not ok then log("checkpoint save failed: " .. tostring(why)) end
            pcall(function() s.vehicle:checkSurroundingChunks();s.vehicle:setPhysicsActive(true,true) end)
        end
        pcall(function() s.player:setBlockMovement(s.wasBlocked) end)
        s.player:getModData().PLVTGuard=nil
        say(s.player,P.status)
        log((success and "COMPLETE " or "STOP ") .. P.status ..
            " id=" .. s.id .. " sqlId=" .. s.sqlId .. " hops=" .. s.hops ..
            " vehicle=" .. s.vehicle:getX() .. "," .. s.vehicle:getY())
    end
    if P.onStopped then P.onStopped(success) end
end

local function candidate(s)
    local x,y=s.vehicle:getX(),s.vehicle:getY()
    local remaining=distance(x,y,s.targetX,s.targetY)
    if remaining<=MAX_STEP+3 then
        -- Final landing searches around the clicked point; a click on a roof,
        -- water or a narrow road may need nearby open ground.
        for radius=0,12 do
            for dx=-radius,radius do for dy=-radius,radius do
                if math.max(math.abs(dx),math.abs(dy))==radius then
                    local cx,cy=math.floor(s.targetX)+dx+0.5,math.floor(s.targetY)+dy+0.5
                    if distance(x,y,cx,cy)<=MAX_STEP+3 then
                        local square=clear(s,cx,cy)
                        if square then return cx,cy,square,true end
                    end
                end
            end end
        end
    end
    local dx,dy=(s.targetX-x)/remaining,(s.targetY-y)/remaining
    local best,bestScore
    for _,length in ipairs({24,18,12,8}) do
        for _,degrees in ipairs({0,22.5,-22.5,45,-45,67.5,-67.5,90,-90}) do
            local angle=degrees*math.pi/180
            local cx=x+length*(dx*math.cos(angle)-dy*math.sin(angle))
            local cy=y+length*(dx*math.sin(angle)+dy*math.cos(angle))
            cx,cy=math.floor(cx)+0.5,math.floor(cy)+0.5
            local nextDistance=distance(cx,cy,s.targetX,s.targetY)
            local progress=remaining-nextDistance
            if progress>1 and (not bestScore or progress>bestScore) then
                local square=clear(s,cx,cy)
                if square then best={cx,cy,square,false};bestScore=progress end
            end
        end
    end
    if best then return unpack(best) end
end

function P.start(player,x,y)
    if P.session then say(player,"A transfer is already running") return false end
    if P.personBusy and P.personBusy() then say(player,"Wait for the person teleport to finish") return false end
    if isClient() or isServer() then say(player,"This experiment currently runs in single-player only") return false end
    if type(umtspMoveVehicle)=="function" then
        say(player,"Disable the Java vehicle add-on before testing the pure Lua version") return false
    end
    local vehicle=player and player:getVehicle()
    if not vehicle then say(player,"Sit in a vehicle first") return false end
    if not finite(x) or not finite(y) then return false end
    if vehicle:getVehicleTowing() or vehicle:getVehicleTowedBy() then
        say(player,"First test: disconnect trailers and use one vehicle") return false
    end
    for seat=0,vehicle:getMaxPassengers()-1 do
        local occupant=vehicle:getCharacter(seat)
        if occupant and occupant~=player then say(player,"First test: use a vehicle with no other passengers") return false end
    end
    if vehicle:getCurrentAbsoluteSpeedKmHour()>1 then say(player,"Stop the vehicle first") return false end
    if player:getZ()~=0 or vehicle:getZ()~=0 then say(player,"Start on ground level") return false end
    local ok,s=pcall(geometry,vehicle)
    if not ok then say(player,tostring(s)) return false end
    s.player=player;s.vehicle=vehicle;s.seat=vehicle:getSeat(player)
    s.id=vehicle:getId();s.sqlId=vehicle:getSqlId();s.targetX=x;s.targetY=y
    s.startX=vehicle:getX();s.startY=vehicle:getY()
    s.total=distance(s.startX,s.startY,x,y);s.hops=0;s.phase="plan"
    s.started=now();s.lastProgress=now();s.nextTick=0;s.ticks=0
    s.wasBlocked=player:isBlockMovement()
    if not registered(s) then say(player,"Vehicle registration is unavailable") return false end
    P.session=s;P.progress=0;P.status="Preparing distant transfer..."
    player:getModData().PLVTGuard={wasBlocked=s.wasBlocked}
    local prepared,why=pcall(function() player:setBlockMovement(true);vehicle:shutOff() end)
    if not prepared then P.stop("Preparation failed: " .. tostring(why));return false end
    if P.onStarted then
        local shown,uiError=pcall(P.onStarted,player)
        if not shown then P.stop("Could not open progress display: " .. tostring(uiError));return false end
    end
    log("START no Java bridge; id=" .. s.id .. " sqlId=" .. s.sqlId ..
        " origin=" .. s.startX .. "," .. s.startY .. " target=" .. x .. "," .. y)
    return true
end

local function update()
    local s=P.session
    if not s then return end
    assert(not s.player:isDead(),"Player died")
    assert(s.player:getVehicle()==s.vehicle,"Player left the vehicle")
    assert(registered(s),"Vehicle identity or world registration changed")
    s.ticks=s.ticks+1
    if now()-s.started>TRIP_TIMEOUT then P.stop("Transfer time limit reached; stopped at the last loaded checkpoint") return end
    if s.ticks<s.nextTick then return end
    if s.phase=="settle" then
        assert(distance(s.vehicle:getX(),s.vehicle:getY(),s.stepX,s.stepY)<2,"Vehicle drifted from its checkpoint")
        followSeat(s)
        if s.final then P.progress=1;P.stop("Vehicle transfer completed",true);return end
        s.phase="plan";s.nextTick=s.ticks+4
        return
    end
    local x,y,square,final=candidate(s)
    if not x then
        P.status="Waiting for loaded open ground... (Esc to stop)"
        if now()-s.lastProgress>STREAM_TIMEOUT then
            P.stop("No loaded open route ahead; stopped with the vehicle at the last checkpoint")
        else s.nextTick=s.ticks+15 end
        return
    end
    -- If a native call throws, try to undo only this short step while its
    -- origin is still loaded. Never jump the player back across unloaded areas.
    local oldX,oldY=s.vehicle:getX(),s.vehicle:getY()
    local oldSquare=getCell():getGridSquare(math.floor(oldX),math.floor(oldY),0)
    local moved,why=pcall(place,s,x,y,square)
    if not moved then
        if registered(s) and oldSquare then
            local restored,reason=pcall(place,s,oldX,oldY,oldSquare)
            log("step rollback=" .. tostring(restored) .. " " .. tostring(reason))
            if restored then pcall(followSeat,s) end
        end
        error(why)
    end
    followSeat(s)
    s.hops=s.hops+1;s.stepX=x;s.stepY=y;s.final=final
    s.phase="settle";s.nextTick=s.ticks+8;s.lastProgress=now()
    P.progress=math.max(0,math.min(0.99,1-distance(x,y,s.targetX,s.targetY)/math.max(1,s.total)))
    P.status=string.format("Moving vehicle: %d%% / %d steps",math.floor(P.progress*100),s.hops)
    if s.hops==1 or s.hops%10==0 or final then
        log("STEP " .. s.hops .. " id=" .. s.id .. " sqlId=" .. s.sqlId .. " at=" .. x .. "," .. y)
    end
end

function P.tick()
    local ok,why=pcall(update)
    if not ok then log("ERROR " .. tostring(why));P.stop("Transfer stopped: " .. tostring(why)) end
end

function P.recover(player)
    local guard=player and player:getModData().PLVTGuard
    if guard then player:setBlockMovement(guard.wasBlocked==true);player:getModData().PLVTGuard=nil end
end

return P
