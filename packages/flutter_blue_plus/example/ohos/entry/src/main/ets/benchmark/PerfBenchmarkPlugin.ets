import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import systemDateTime from '@ohos.systemDateTime';
import hidebug from '@ohos.hidebug';

// Example-only instrumentation. No handler is installed on the production channel.
export default class PerfBenchmarkPlugin implements FlutterPlugin, MethodCallHandler {
  private control: MethodChannel | null = null;
  private production: MethodChannel | null = null;
  private timer: number = -1;
  private deadline: number = -1;
  private pending: MethodResult | null = null;
  private generation: number = 0;

  private filesDir: string;

  constructor(filesDir: string) { this.filesDir = filesDir; }

  getUniqueClassName(): string { return 'PerfBenchmarkPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.control = new MethodChannel(binding.getBinaryMessenger(), 'fbp_example/performance');
    this.production = new MethodChannel(binding.getBinaryMessenger(), 'flutter_blue_plus/methods');
    this.control.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.stop();
    this.control?.setMethodCallHandler(null);
    this.control = null;
    this.production = null;
  }

  private nowUs(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000;
  }

  private stop(): void {
    this.generation++;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (this.deadline >= 0) { clearTimeout(this.deadline); this.deadline = -1; }
    this.pending?.error('cancelled', 'Event run cancelled', null);
    this.pending = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'echo':
        result.success(call.args);
        break;
      case 'filesDir':
        result.success(this.filesDir);
        break;
      case 'memory': {
        const mem = hidebug.getAppNativeMemInfo();
        const values = new Map<string, Object>();
        values.set('pss_kb', Number(mem.pss));
        values.set('rss_kb', Number(mem.rss));
        values.set('private_dirty_kb', Number(mem.privateDirty));
        result.success(values);
        break;
      }
      case 'events':
        this.events(call, result);
        break;
      case 'stop':
        this.stop();
        result.success(null);
        break;
      default:
        result.notImplemented();
    }
  }

  private events(call: MethodCall, result: MethodResult): void {
    if (this.pending !== null) {
      result.error('busy', 'An event run is already active', null);
      return;
    }
    const args = call.args as Map<string, Object>;
    const count = args.get('count') as number;
    const hz = args.get('hz') as number;
    const size = args.get('size') as number;
    const plugin = args.get('plugin') as boolean;
    if (count < 1 || count > 10000 || hz < 1 || hz > 1000 || size < 4 || size > 65536) {
      result.error('arguments', 'Invalid event parameters', null);
      return;
    }
    const channel = plugin ? this.production : this.control;
    if (channel === null) { result.error('detached', 'Engine detached', null); return; }
    const generation = ++this.generation;
    let sent = 0;
    let replies = 0;
    let errors = 0;
    let previous = 0;
    const rtts: number[] = [];
    const intervals: number[] = [];
    const started = this.nowUs();
    this.pending = result;
    const finishReply = (start: number, failed: boolean): void => {
      if (generation !== this.generation) { return; }
      if (failed) { errors++; } else { rtts.push(this.nowUs() - start); }
      replies++;
      if (sent === count && replies === count) {
        clearTimeout(this.deadline);
        this.deadline = -1;
        const output = new Map<string, Object>();
        output.set('sent', sent);
        output.set('replies', replies);
        output.set('errors', errors);
        output.set('native_rtt_us', rtts);
        output.set('native_interval_us', intervals);
        output.set('native_elapsed_us', this.nowUs() - started);
        this.pending = null;
        result.success(output);
      }
    };
    this.deadline = setTimeout(() => { this.stop(); }, count * 1000 / hz + 10000);
    this.timer = setInterval(() => {
      const sequence = sent++;
      const value = new Uint8Array(size);
      for (let i = 4; i < size; i++) { value[i] = i % 251; }
      new DataView(value.buffer).setUint32(0, sequence, true);
      const envelope = new Map<string, Object>();
      envelope.set('remote_id', '02:00:00:00:00:01');
      envelope.set('service_uuid', '180f');
      envelope.set('characteristic_uuid', '2a19');
      envelope.set('instance_id', 0);
      envelope.set('value', value);
      envelope.set('success', 1);
      envelope.set('error_code', 0);
      envelope.set('error_string', 'GATT_SUCCESS');
      const start = this.nowUs();
      if (previous !== 0) { intervals.push(start - previous); }
      previous = start;
      // RTT includes codec, engine scheduling, Dart handler and its automatic reply.
      const callback: MethodResult = {
        success: (): void => { finishReply(start, false); },
        error: (): void => { finishReply(start, true); },
        notImplemented: (): void => { finishReply(start, true); }
      };
      channel.invokeMethod(plugin ? 'OnCharacteristicReceived' : 'sample', envelope, callback);
      if (sent === count) { clearInterval(this.timer); this.timer = -1; }
    }, 1000 / hz);
  }
}
