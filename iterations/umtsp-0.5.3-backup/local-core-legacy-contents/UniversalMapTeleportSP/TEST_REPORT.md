# 测试与审核记录

日期：2026-10-19。目标：Project Zomboid 42.21 单机与多人版。本机 `Zomboid/console.txt` 报告 `version=42.21.0`。

## 第一轮：Lua 语法与 API

- 使用 `luaparser` 解析客户端、配置和服务器 Lua 文件：通过。
- 对照本机 B42.21 `ISWorldMap.lua` 核实 `onRightMouseUp`、`mapAPI:uiToWorldX/Y`、`isValidChunk`、`onTeleport` 与 `teleportTo`。
- 对照本机 `ISContextMenu.lua` 核实 `get` 会清空菜单、`addOptionOnTop` 会保留旧选项。
- 对照本机 `keyBinding.lua`、`ISSearchManager.lua`、`MainOptions.lua` 核实 OnGameBoot 追加按键绑定和 `getCore():getKey` 的用法。
- 对照本机 Lua 代码核实 `getGridSquare`、`getFloor`、`isFree(false)`、`IsoFlagType.water` 的用法。

## 第二轮：菜单兼容

- 阅读本机 DerpyAutodrive 42.19 的 `map_nav.lua`：它包装原回调，根据返回值复用或重建 Context Menu。
- 阅读本机 MapTeleport 的 `MapTeleport.lua`：它直接替换 `ISWorldMap:onRightMouseUp`。
- 通过 Lua 模拟环境执行本模组脚本：AutoDrive 先加载、后加载两种顺序下，菜单均为 `Teleport Here`、`Add Destination`；点击传送选项调用传送回调。通过。
- 同一菜单重复触发右键：不重复加入本模组选项。通过。
- 原版 Debug/管理员菜单已有同名传送项时，本模组仍补入独立的 Teleport Here，两项并存。通过。
- 模拟 GPS 路线、地图标记、作弊传送三项已存在时，本模组的选项与三项同时显示，各有独立回调。通过。
- 模拟第三方替换地图右键回调后，地图指针快捷键仍调用传送。通过。
- 模拟游戏开始后被替换右键回调，再次打开地图时重新包装，并保留新模组菜单项。通过。

## 第三轮：坐标、安全与旧存档

- 模拟地图坐标转换与玩家传送到格子中心：通过。
- 模拟多人客户端向服务器发送请求，服务器移动请求者，到达后完成：通过。
- 模拟多人远距离目标加载后验证、危险落点返回原点、受阻落点经服务器调整：通过。
- 模拟服务器仅移动发出请求的玩家、忽略其他玩家的落点调整、拒绝无效坐标：通过。
- 模拟远端地格未加载：先调用原版传送，等待载入后验证。通过。
- 模拟远端落点不可站立：返回原点。通过。
- 模拟所选格不可站立、邻格可站立：调整到邻格。通过。
- 模拟远端区块一直未加载：600 tick 后返回原点。通过。
- 本模组不写入存档，也不需要新游戏；旧存档启用仍需游戏内核验。
- 远距离跨城地格的加载时序、房屋内碰撞及短暂未验证落点仍需游戏内测试，详见 README。

## 尚未完成的游戏内验收

当前 ProjectZomboid64 进程仍可能加载旧代码。需退出并重启游戏与服务器、启用 0.2.1 后验证：

1. B42.21 加载和旧存档启停，无 Lua Error。
2. 右键菜单显示、点击真实传送；不同缩放和拖动后的坐标。
3. AutoDrive 单独及共同启用、两种加载顺序、`Add Destination` 的实际回调。
4. Cheat Menu 原功能与重复选项。
5. 远距离地点的加载、墙边/水边落点调整、多层建筑、连续多次传送，以及失败后返回原点。
6. 用户自定义快捷键是否在游戏选项里显示并生效。
7. 联机主机和专用服务器：普通玩家的请求、跨城加载、落点调整、返回原位、连续请求以及断线重连。
8. Project Remnants、MapTeleport、Cheat Menu Rebuild、ZombieBuddy 和其他地图模组的实际组合兼容性。
9. 车辆与乘客一起传送尚未实现；当前代码会在乘车时拒绝传送。车辆跨区块物理和多人同步需要单独设计与游戏内验证。

测试模拟脚本位于本次工作区 `work/test_umtsp.py`，不包含在模组包内。
