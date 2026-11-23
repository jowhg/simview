#import "dtuhid.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <xpc/xpc.h>

static NSString *const kDigitizerService = @"com.apple.coredevice.feature.remote.hid.digitizer";

// Private libxpc entry points made for simulators. Both creators return +1 objects.
typedef xpc_object_t (*SVEndpointFromPort)(mach_port_t port, uint64_t a, uint64_t b) __attribute__((ns_returns_retained));
typedef xpc_connection_t (*SVConnectionFromEndpoint)(xpc_object_t endpoint) __attribute__((ns_returns_retained));
typedef void (*SVEnableSim2Host)(xpc_connection_t connection);

@protocol SVSimDeviceLookup <NSObject>
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
@end

static NSError *SVError(NSString *message) {
  return [NSError errorWithDomain:@"simview.dtuhid" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

static xpc_object_t SVPoint(double x, double y) {
  xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_double(point, "x", x);
  xpc_dictionary_set_double(point, "y", y);
  return point;
}

static xpc_object_t SVMessage(NSString *type, BOOL barrier, xpc_object_t payload) {
  xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(message, "messageType", type.UTF8String);
  xpc_dictionary_set_bool(message, "isBarrier", barrier);
  xpc_dictionary_set_string(message, "featureIdentifier", kDigitizerService.UTF8String);
  xpc_dictionary_set_value(message, "payload", payload);
  return message;
}

static xpc_object_t SVKeyPayload(uint64_t usage, BOOL down) {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
  return payload;
}

@interface SVDTUHID ()
@property (atomic, readwrite) BOOL invalid;
@end

@implementation SVDTUHID {
  xpc_connection_t _connection;
}

+ (instancetype)connectToDevice:(id)device error:(NSError **)error {
  SVEndpointFromPort endpointFromPort = (SVEndpointFromPort)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
  SVConnectionFromEndpoint connectionFromEndpoint = (SVConnectionFromEndpoint)dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
  SVEnableSim2Host enableSim2Host = (SVEnableSim2Host)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
  if (!endpointFromPort || !connectionFromEndpoint || !enableSim2Host) {
    if (error) *error = SVError(@"libxpc simulator entry points are missing");
    return nil;
  }

  NSError *lookupError = nil;
  mach_port_t port = [(id<SVSimDeviceLookup>)device lookup:kDigitizerService error:&lookupError];
  if (port == MACH_PORT_NULL) {
    if (error) *error = lookupError ?: SVError(@"dtuhidd digitizer service not found in the simulator");
    return nil;
  }

  xpc_object_t endpoint = endpointFromPort(port, 0, 0);  // consumes the send right
  xpc_connection_t connection = endpoint ? connectionFromEndpoint(endpoint) : nil;
  if (!connection) {
    if (error) *error = SVError(@"could not create an XPC connection to dtuhidd");
    return nil;
  }
  enableSim2Host(connection);
  SVDTUHID *hid = [SVDTUHID new];
  __weak SVDTUHID *weakHID = hid;
  xpc_connection_set_target_queue(connection, dispatch_queue_create("simview.dtuhid", DISPATCH_QUEUE_SERIAL));
  xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
    if (event == XPC_ERROR_CONNECTION_INTERRUPTED || event == XPC_ERROR_CONNECTION_INVALID) weakHID.invalid = YES;
  });
  xpc_connection_resume(connection);

  // Liveness probe: a barrier carrying "no key" that dtuhidd answers once it is up and activated.
  dispatch_semaphore_t answered = dispatch_semaphore_create(0);
  __block BOOL alive = NO;
  xpc_connection_send_message_with_reply(connection, SVMessage(@"IndigoKeyboardButtonEvent", YES, SVKeyPayload(0, NO)),
                                         dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
                                           alive = xpc_get_type(reply) != XPC_TYPE_ERROR;
                                           dispatch_semaphore_signal(answered);
                                         });
  if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) != 0 || !alive) {
    xpc_connection_cancel(connection);
    if (error) *error = SVError(@"dtuhidd did not answer the liveness barrier");
    return nil;
  }
  usleep(200 * 1000);  // let the peer finish opening its HID device

  hid->_connection = connection;
  return hid;
}

- (void)send:(NSString *)type payload:(xpc_object_t)payload {
  xpc_connection_send_message(_connection, SVMessage(type, NO, payload));
}

- (void)touch:(SVTouchPhase)phase x:(double)x y:(double)y {
  [self touch:phase x:x y:y edge:SVEdgeNone];
}

- (void)touch:(SVTouchPhase)phase x:(double)x y:(double)y edge:(SVEdge)edge {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(payload, "pointOne", SVPoint(x, y));
  xpc_dictionary_set_uint64(payload, "eventType", phase);
  xpc_dictionary_set_uint64(payload, "edge", edge);
  xpc_dictionary_set_uint64(payload, "target", 0);
  [self send:@"IndigoDigitizerEvent" payload:payload];
}

- (void)doublePressHome {
  [self pressButton:SVButtonHome];
  usleep(90 * 1000);
  [self pressButton:SVButtonHome];
}

- (void)touch:(SVTouchPhase)phase x:(double)x y:(double)y x2:(double)x2 y2:(double)y2 {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(payload, "pointOne", SVPoint(x, y));
  xpc_dictionary_set_value(payload, "pointTwo", SVPoint(x2, y2));
  xpc_dictionary_set_uint64(payload, "eventType", phase);
  xpc_dictionary_set_uint64(payload, "edge", 0);
  xpc_dictionary_set_uint64(payload, "target", 0);
  [self send:@"IndigoDigitizerEvent" payload:payload];
}

- (void)pressButton:(SVButton)button {
  [self pressUsagePage:0x0C usage:button];
}

- (void)pressUsagePage:(uint64_t)page usage:(uint64_t)usage {
  for (int state = 1; state <= 2; state++) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usagePage", page);
    xpc_dictionary_set_uint64(payload, "usageCode", usage);
    xpc_dictionary_set_uint64(payload, "state", state);
    [self send:@"IndigoButtonEvent" payload:payload];
    if (state == 1) usleep(60 * 1000);
  }
}

- (void)buttonUsagePage:(uint64_t)page usage:(uint64_t)usage down:(BOOL)down {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usagePage", page);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
  [self send:@"IndigoButtonEvent" payload:payload];
}

- (void)key:(uint64_t)usage down:(BOOL)down {
  [self send:@"IndigoKeyboardButtonEvent" payload:SVKeyPayload(usage, down)];
}

- (void)disconnect {
  if (_connection) xpc_connection_cancel(_connection);
  _connection = nil;
}

- (void)dealloc {
  [self disconnect];
}

@end
