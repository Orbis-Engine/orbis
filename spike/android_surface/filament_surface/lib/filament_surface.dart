
import 'filament_surface_platform_interface.dart';

class FilamentSurface {
  Future<String?> getPlatformVersion() {
    return FilamentSurfacePlatform.instance.getPlatformVersion();
  }
}
