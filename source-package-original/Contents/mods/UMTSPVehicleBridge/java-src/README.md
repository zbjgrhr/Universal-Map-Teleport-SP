# Vehicle bridge build (B42.21)

`com/umtsp/VehicleBridge.java` is the source for `42/media/java/UMTSPVehicle.jar`.
Compile with JDK 25 against the installed B42.21 `projectzomboid.jar` and ZombieBuddy 2.3.4 `ZombieBuddy.jar`, then package the compiled `com/` tree as `UMTSPVehicle-0.5.0.jar`. Do not include game or ZombieBuddy classes in the JAR.

The server vehicle resync technique was informed by the public-domain [Necroid vehicle-teleport-41 example](https://github.com/mrkmg/necroid/blob/main/mods/vehicle-teleport-41/README.md). This implementation uses B42.21 vehicle packets and per-connection state. It has not been verified inside a running multiplayer server.
