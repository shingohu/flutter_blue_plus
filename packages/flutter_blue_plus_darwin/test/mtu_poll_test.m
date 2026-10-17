// Run with: python3 test/run_native_tests.py
// Compile the production plugin; only the peripheral and channel are faked.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/FlutterBluePlusPlugin.m"
#pragma clang diagnostic pop
#include <math.h>
#include <stdlib.h>

static void expect(BOOL condition, NSString *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

@interface TestPeripheral : NSObject<NSCopying>
@property(nonatomic) NSUUID *identifier;
@property(nonatomic) CBPeripheralState state;
@property(nonatomic) id delegate;
@property(nonatomic) int mtu;
@end

@implementation TestPeripheral
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@interface TestChannel : NSObject
@property(nonatomic) NSMutableArray<NSDictionary *> *mtuEvents;
@end

@implementation TestChannel
- (void)invokeMethod:(NSString *)method arguments:(id)arguments
{
    if ([method isEqualToString:@"OnMtuChanged"]) {
        [self.mtuEvents addObject:arguments];
    }
}
@end

@interface TestPlugin : FlutterBluePlusPlugin
@end

@implementation TestPlugin
- (int)getMtu:(CBPeripheral *)peripheral
{
    return ((TestPeripheral *)peripheral).mtu;
}
@end

static TestPlugin *makePlugin(void)
{
    TestPlugin *plugin = [TestPlugin new];
    plugin.connectedPeripherals = [NSMutableDictionary new];
    plugin.currentlyConnectingPeripherals = [NSMutableDictionary new];
    plugin.peripheralMtu = [NSMutableDictionary new];
    plugin.peripheralMtuStableTicks = [NSMutableDictionary new];
    plugin.servicesToDiscover = [NSMutableDictionary new];
    plugin.characteristicsToDiscover = [NSMutableDictionary new];
    plugin.discoveryErrors = [NSMutableDictionary new];
    plugin.didWriteWithoutResponse = [NSMutableDictionary new];
    plugin.writeChrs = [NSMutableDictionary new];
    plugin.writeDescs = [NSMutableDictionary new];
    TestChannel *channel = [TestChannel new];
    channel.mtuEvents = [NSMutableArray new];
    plugin.methodChannel = (FlutterMethodChannel *)channel;
    return plugin;
}

static TestPeripheral *connectPeripheral(TestPlugin *plugin, int mtu)
{
    TestPeripheral *peripheral = [TestPeripheral new];
    peripheral.identifier = [NSUUID UUID];
    peripheral.state = CBPeripheralStateConnected;
    peripheral.mtu = mtu;
    [plugin centralManager:plugin.centralManager didConnectPeripheral:(CBPeripheral *)peripheral];
    return peripheral;
}

static void poll(TestPlugin *plugin, int ticks)
{
    // Fire the real NSTimer deterministically; do not wait on wall-clock time.
    for (int i = 0; i < ticks; i++) {
        [plugin.checkForMtuChangesTimer fire];
    }
}

static NSArray<NSDictionary *> *events(TestPlugin *plugin)
{
    return ((TestChannel *)plugin.methodChannel).mtuEvents;
}

static void disconnectPeripheral(TestPlugin *plugin, TestPeripheral *peripheral)
{
    peripheral.state = CBPeripheralStateDisconnected;
    [plugin centralManager:plugin.centralManager didDisconnectPeripheral:(CBPeripheral *)peripheral error:nil];
}

static void testDelayedNegotiation(void)
{
    TestPlugin *plugin = makePlugin();
    TestPeripheral *peripheral = connectPeripheral(plugin, 23);
    poll(plugin, 25);
    peripheral.mtu = 185;
    poll(plugin, 1);
    expect(events(plugin).count == 2 && [events(plugin).lastObject[@"mtu"] intValue] == 185,
           @"delayed negotiation must still update the MTU after the initial settle window");
    expect(fabs(plugin.checkForMtuChangesTimer.timeInterval - 0.1) < 0.001,
           @"an MTU change must restore fast polling");

    poll(plugin, 25);
    expect(plugin.checkForMtuChangesTimer.valid && plugin.checkForMtuChangesTimer.timeInterval >= 1.0,
           @"a stable connection must retain low-frequency polling");
    expect(events(plugin).count == 2, @"unchanged MTUs must not emit duplicate events");
    peripheral.mtu = 100;
    poll(plugin, 1);
    expect([events(plugin).lastObject[@"mtu"] intValue] == 100,
           @"subsequent MTU changes must also reach Dart");
    [plugin disarmMtuPoll];
    puts("PASS: delayed negotiation and subsequent MTU changes");
}

static void testMultipleConnectionsAndReconnect(void)
{
    TestPlugin *plugin = makePlugin();
    TestPeripheral *first = connectPeripheral(plugin, 23);
    poll(plugin, 25);
    NSTimer *slowTimer = plugin.checkForMtuChangesTimer;
    TestPeripheral *second = connectPeripheral(plugin, 185);
    expect(!slowTimer.valid && fabs(plugin.checkForMtuChangesTimer.timeInterval - 0.1) < 0.001,
           @"a new connection must replace slow polling with fast polling");
    poll(plugin, 1);
    disconnectPeripheral(plugin, second);
    poll(plugin, 25);
    first.mtu = 100;
    poll(plugin, 1);
    expect([events(plugin).lastObject[@"mtu"] intValue] == 100,
           @"disconnecting one device must leave the remaining device observable");

    disconnectPeripheral(plugin, first);
    expect(plugin.checkForMtuChangesTimer == nil, @"the final disconnect must stop polling immediately");
    expect(plugin.peripheralMtu.count == 0 && plugin.peripheralMtuStableTicks.count == 0,
           @"disconnects must clear per-connection MTU state");
    first.state = CBPeripheralStateConnected;
    [plugin centralManager:plugin.centralManager didConnectPeripheral:(CBPeripheral *)first];
    poll(plugin, 1);
    expect(events(plugin).count == 4 && [events(plugin).lastObject[@"mtu"] intValue] == 100,
           @"reconnecting the same peripheral must emit a fresh MTU");
    disconnectPeripheral(plugin, first);
    puts("PASS: multiple connections, final disconnect, and reconnect");
}

static void testAdapterOff(void)
{
    TestPlugin *plugin = makePlugin();
    connectPeripheral(plugin, 185);
    poll(plugin, 25);
    NSTimer *timer = plugin.checkForMtuChangesTimer;
    [plugin disconnectAllDevices:@"adapterTurnOff"];
    expect(plugin.checkForMtuChangesTimer == nil && !timer.valid,
           @"turning off Bluetooth must stop even a slow polling timer immediately");
    expect(plugin.peripheralMtuStableTicks.count == 0, @"adapter shutdown must clear settle state");
    puts("PASS: adapter shutdown");
}

int main(void)
{
    @autoreleasepool {
        testDelayedNegotiation();
        testMultipleConnectionsAndReconnect();
        testAdapterOff();
    }
    return 0;
}
