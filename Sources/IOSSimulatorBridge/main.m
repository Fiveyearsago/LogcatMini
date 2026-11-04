// Isolated adapter for Xcode's simulator runtime. No private framework is linked into Logcat Mini.
// DTUHID wire protocol / simulator XPC lookup adapted from Meta idb (MIT); see docs/licenses/idb.txt.
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <xpc/xpc.h>
#import <dlfcn.h>
#import <signal.h>
#import <objc/message.h>
#import <time.h>

// Runtime-only declarations: selectors can change independently of the host macOS SDK.
@interface NSObject (SimulatorRuntime)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)path error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (NSUUID *)UDID;
- (NSUInteger)state;
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
- (id)io;
- (NSArray *)ioPorts;
- (id)descriptor;
- (unsigned short)displayClass;
- (id)framebufferSurface;
- (id)ioSurface;
@end

static const char *service = "com.apple.coredevice.feature.remote.hid.digitizer";
static NSLock *outputLock;
static xpc_connection_t connection;
static BOOL touching;
static double lastX, lastY;
static uint64_t lastTouchTime;
static NSMutableSet<NSNumber *> *heldKeys;
static volatile sig_atomic_t stopping;
static void onSignal(int value) { stopping = 1; }
static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    [outputLock lock];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
    [outputLock unlock];
}
static void fail(NSString *message) { emit(@{@"event": @"error", @"message": message}); }
static xpc_object_t message(const char *type, xpc_object_t payload, BOOL barrier) {
    xpc_object_t value = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(value, "messageType", type);
    xpc_dictionary_set_string(value, "featureIdentifier", service);
    xpc_dictionary_set_bool(value, "isBarrier", barrier);
    xpc_dictionary_set_value(value, "payload", payload);
    return value;
}
static xpc_object_t keyMessage(uint64_t usage, BOOL down, BOOL barrier) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usageCode", usage);
    xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
    return message("IndigoKeyboardButtonEvent", payload, barrier);
}
static void key(uint64_t usage, BOOL down) {
    xpc_connection_send_message(connection, keyMessage(usage, down, NO));
    if (down) [heldKeys addObject:@(usage)]; else [heldKeys removeObject:@(usage)];
}
static void touch(uint64_t phase, double x, double y) {
    if (phase > 2 || !isfinite(x) || !isfinite(y)) return;
    if (phase != 0 && !touching) return;
    if (phase == 0 && touching) touch(2, lastX, lastY);
    // UIKit coalesces packets delivered in the same display tick. Keep a very short drag/wheel
    // from losing its down event when stdin and XPC flush several packets together.
    if (phase != 0 && lastTouchTime) {
        uint64_t elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - lastTouchTime;
        if (elapsed < 16 * NSEC_PER_MSEC) usleep((useconds_t)((16 * NSEC_PER_MSEC - elapsed) / 1000));
    }
    lastX = fmin(1, fmax(0, x)); lastY = fmin(1, fmax(0, y)); touching = phase != 2;
    xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(point, "x", lastX); xpc_dictionary_set_double(point, "y", lastY);
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", point);
    xpc_dictionary_set_uint64(payload, "eventType", phase);
    xpc_dictionary_set_uint64(payload, "edge", 0); xpc_dictionary_set_uint64(payload, "target", 0);
    xpc_connection_send_message(connection, message("IndigoDigitizerEvent", payload, NO));
    lastTouchTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
static void releaseInput(void) {
    if (touching) touch(2, lastX, lastY);
    for (NSNumber *usage in heldKeys.allObjects) key(usage.unsignedLongLongValue, NO);
}
static BOOL roundTrip(void) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    xpc_connection_send_message_with_reply(connection, keyMessage(0, NO, YES), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
        ok = xpc_get_type(reply) != XPC_TYPE_ERROR; dispatch_semaphore_signal(semaphore);
    });
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0 && ok;
}
static BOOL pasteText(NSString *text, NSString *udid) {
    // Only the selected simulator's clipboard is changed. No shell interpolation or host clipboard mutation.
    NSTask *child = [NSTask new]; NSPipe *input = [NSPipe pipe];
    child.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    child.arguments = @[@"devicectl", @"device", @"pasteboard", @"copy", @"--device", udid, @"--timeout", @"5", @"--quiet"];
    child.standardInput = input; child.standardOutput = [NSFileHandle fileHandleWithNullDevice]; child.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error;
    if (![child launchAndReturnError:&error]) return NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ if (child.running) [child terminate]; });
    [input.fileHandleForWriting writeData:[text dataUsingEncoding:NSUTF8StringEncoding]]; [input.fileHandleForWriting closeFile];
    [child waitUntilExit]; if (child.terminationStatus || stopping) return NO;
    key(227, YES); key(25, YES); key(25, NO); key(227, NO); // Left GUI + V
    if (!roundTrip()) return NO;
    usleep(80000); // allow the focused editor to consume its paste before the next text command
    return YES;
}
static BOOL sendTextInput(NSString *text, NSString *udid) {
    // Text was already composed by the Mac input method. Replaying Latin HID keys would run it
    // through the guest IME a second time (e.g. '_' / '!' become Chinese punctuation).
    return pasteText(text, udid);
}
static id findScreen(id device) {
    for (id port in [[device io] ioPorts]) {
        id descriptor = [port descriptor];
        if ([descriptor respondsToSelector:@selector(framebufferSurface)] &&
            [descriptor respondsToSelector:@selector(state)] &&
            [((id (*)(id, SEL))objc_msgSend)(descriptor, @selector(state)) displayClass] == 0) return descriptor;
    }
    return nil;
}
static void streamFrames(id screen) {
    CIContext *context = [CIContext contextWithOptions:nil];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    while (!stopping) { @autoreleasepool {
        uint64_t frameStarted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        @try {
            id object = [screen framebufferSurface];
            if (!object && [screen respondsToSelector:@selector(ioSurface)]) object = [screen ioSurface];
            if (object && CFGetTypeID((__bridge CFTypeRef)object) == IOSurfaceGetTypeID()) {
                IOSurfaceRef surface = (__bridge IOSurfaceRef)object; IOSurfaceIncrementUseCount(surface);
                CIImage *image = [CIImage imageWithIOSurface:surface options:@{kCIImageColorSpace: (__bridge id)colorSpace}];
                // Preserve every simulator pixel. A 960px JPEG is visibly blurred when AppKit
                // enlarges it on a Retina display, especially around small text and coloured edges.
                NSData *png = [context PNGRepresentationOfImage:image format:kCIFormatRGBA8 colorSpace:colorSpace options:@{}];
                IOSurfaceDecrementUseCount(surface);
                if (png) emit(@{@"event": @"frame", @"png": [png base64EncodedStringWithOptions:0]});
            }
        } @catch (NSException *exception) { fail(@"模拟器画面通道已断开，请重新连接投屏。"); stopping = 1; }
        // Include encoding / pipe time in the frame budget, rather than sleeping another 80ms
        // after each larger lossless frame. Still bounded to 12 fps with no catch-up bursts.
        uint64_t elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - frameStarted;
        uint64_t budget = NSEC_PER_SEC / 12;
        if (elapsed < budget) usleep((useconds_t)((budget - elapsed) / 1000));
    }}
    CGColorSpaceRelease(colorSpace);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    outputLock = [NSLock new]; heldKeys = [NSMutableSet set]; signal(SIGPIPE, SIG_IGN);
    struct sigaction action = {0}; action.sa_handler = onSignal; sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL);
    if (argc < 3) { fail(@"需要 Xcode Developer 目录和模拟器 UDID。"); return 2; }
    NSString *developer = @(argv[1]), *udid = @(argv[2]);
    setenv("DEVELOPER_DIR", developer.UTF8String, 1);
    if (![[NSUUID alloc] initWithUUIDString:udid]) { fail(@"无效的模拟器 UDID。"); return 2; }
    @try {
        NSArray *frameworks = @[[developer stringByAppendingPathComponent:@"Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"],
                                @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"];
        BOOL loaded = NO; for (NSString *path in frameworks) if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) { loaded = YES; break; }
        if (!loaded) { fail(@"无法加载所选 Xcode 的 CoreSimulator。"); return 1; }
        NSError *error;
        id context = [NSClassFromString(@"SimServiceContext") sharedServiceContextForDeveloperDir:developer error:&error];
        id set = [context defaultDeviceSetWithError:&error], device = nil;
        for (id candidate in [set availableDevices]) if ([[candidate UDID].UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) { device = candidate; break; }
        if (!device || [device state] != 3) { fail(@"目标模拟器未启动或已断开。"); return 1; }
        xpc_object_t (*endpointFromPort)(mach_port_t, uint64_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
        void (*enableSim2Host)(xpc_connection_t) = dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
        if (!endpointFromPort || !enableSim2Host) { fail(@"此 Xcode 尚不支持内嵌模拟器控制，请使用模拟器窗口操作。"); return 1; }
        BOOL connected = NO;
        for (int attempt = 0; attempt < 3 && !stopping; attempt++) {
            mach_port_t port = [device lookup:@(service) error:&error];
            if (!port) { usleep(300000); continue; }
            xpc_object_t endpoint = endpointFromPort(port, 0, 0);
            connection = xpc_connection_create_from_endpoint(endpoint); enableSim2Host(connection);
            xpc_connection_set_target_queue(connection, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
            xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
                if (xpc_get_type(event) == XPC_TYPE_ERROR && !stopping) { /* roundTrip detects failed initial connections */ }
            });
            xpc_connection_resume(connection);
            if (roundTrip()) { connected = YES; break; }
            xpc_connection_cancel(connection); connection = nil; usleep(300000);
        }
        if (!connected) { fail(@"模拟器输入通道不可用。请等待启动完成后重连；旧运行时可打开模拟器窗口操作。"); return 1; }
        usleep(200000);
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_ERROR && !stopping) {
                fail(@"模拟器输入通道已断开，请重新连接投屏。"); _exit(1);
            }
        });
        id screen = findScreen(device);
        if (argc > 3 && screen) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ streamFrames(screen); });
        emit(@{@"event": @"ready", @"device": udid, @"frames": @(screen != nil && argc > 3)});
        char *line = NULL; size_t capacity = 0;
        while (!stopping && getline(&line, &capacity, stdin) > 0) { @autoreleasepool {
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:[[@(line) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![command isKindOfClass:NSDictionary.class]) continue;
            NSString *type = command[@"type"];
            if ([type isEqual:@"touch"]) touch([command[@"phase"] unsignedLongLongValue], [command[@"x"] doubleValue], [command[@"y"] doubleValue]);
            else if ([type isEqual:@"key"]) key([command[@"usage"] unsignedLongLongValue], [command[@"down"] boolValue]);
            else if ([type isEqual:@"text"]) {
                NSString *text = command[@"text"];
                if (![text isKindOfClass:NSString.class] || text.length > 4096 || !sendTextInput(text, udid)) { fail(@"文字发送失败，请确认模拟器中的输入框已聚焦后重试。"); continue; }
            }
            else if ([type isEqual:@"release"]) releaseInput();
            else if ([type isEqual:@"quit"]) break;
            else if ([type isEqual:@"barrier"] && !roundTrip()) { fail(@"模拟器输入通道已断开，请重连。"); break; }
            if (command[@"id"]) emit(@{@"event": @"ack", @"id": command[@"id"]});
        }}
        free(line); stopping = 1; releaseInput(); (void)roundTrip(); usleep(80000); xpc_connection_cancel(connection);
    } @catch (NSException *exception) { fail([@"当前 Xcode 的模拟器接口不兼容：" stringByAppendingString:exception.reason ?: @"未知错误"]); return 1; }
    return 0;
}}
