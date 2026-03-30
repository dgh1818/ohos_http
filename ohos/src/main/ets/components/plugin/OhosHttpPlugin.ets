import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos';

import { NativeHttpApiOhos } from './NativeHttpApiOhos.g';
import { NativeHttpApiImpl } from './NativeHttpApiImpl';

export default class OhosHttpPlugin implements FlutterPlugin {
  getUniqueClassName(): string {
    return 'OhosHttpPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const messenger = binding.getBinaryMessenger();
    const context = binding.getApplicationContext();
    NativeHttpApiOhos.setup(messenger, new NativeHttpApiImpl(context, messenger));
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    NativeHttpApiOhos.setup(binding.getBinaryMessenger(), null);
  }
}
