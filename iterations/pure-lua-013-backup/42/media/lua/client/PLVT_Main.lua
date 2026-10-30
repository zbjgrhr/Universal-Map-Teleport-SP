require "ISUI/Maps/ISWorldMap"
require "ISUI/ISPanel"
require "ISUI/ISButton"
local P=require "PLVT_Core"
local window

local function showProgress(player)
    ISWorldMap.HideWorldMap(player:getPlayerNum())
    if window then window:removeFromUIManager() end
    local panel=ISPanel:new((getCore():getScreenWidth()-460)/2,50,460,125)
    panel:initialise();panel:addToUIManager()
    panel.backgroundColor={r=0.04,g=0.06,b=0.08,a=0.95}
    function panel:prerender()
        ISPanel.prerender(self)
        self:drawText("PURE LUA VEHICLE TEST",12,10,1,0.8,0.25,1,UIFont.Small)
        self:drawText(P.status,12,34,1,1,1,1,UIFont.Small)
        self:drawRect(12,59,436,8,1,0.2,0.2,0.2)
        self:drawRect(12,59,436*P.progress,8,1,1,0.7,0.1)
    end
    local cancel=ISButton:new(12,80,436,28,"Cancel at current checkpoint (Esc)",panel,function()
        P.stop("Cancelled with the vehicle at the current loaded checkpoint")
    end)
    cancel:initialise();panel:addChild(cancel)
    window=panel
end

P.onStarted=showProgress
P.onStopped=function()
    if window then window:removeFromUIManager();window=nil end
end

Events.OnGameStart.Add(function()
    P.recover(getSpecificPlayer(0))
    print("[PureLuaVehicleTest] Loaded 0.1.2; person/animal teleport included; no Java required")
end)
Events.OnTick.Add(P.tick)
Events.OnKeyPressed.Add(function(key)
    if P.session and key==Keyboard.KEY_ESCAPE then
        P.stop("Cancelled with the vehicle at the current loaded checkpoint")
    end
end)
