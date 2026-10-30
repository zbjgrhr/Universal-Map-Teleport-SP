import zombie.vehicles.VehicleIDMap;
import zombie.vehicles.BaseVehicle;
public class RegistrationTest {
  static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); }
  public static void main(String[] args) {
    VehicleIDMap map = VehicleIDMap.instance;
    BaseVehicle car = new BaseVehicle();
    short id = map.allocateID(); map.put(id, car);
    for (int i=0; i<1000; i++) {
      check(map.get(id)==car, "missing registration before unload");
      map.remove(id);
      // Another vehicle can claim the released ID before the car rejoins.
      BaseVehicle other = new BaseVehicle();
      short otherId = map.allocateID(); map.put(otherId, other);
      id = map.allocateID(); map.put(id, car);
      check(id!=otherId && map.get(otherId)==other && map.get(id)==car, "ID collision");
      map.remove(otherId);
    }
    map.remove(id);
    System.out.println("PASS: 1000 unload/rejoin cycles, with intervening ID reuse; final unload succeeds");
  }
}
